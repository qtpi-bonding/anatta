# Meta-Harness: External Supervision, Health Checks, and Rollback

> **v2.** Rewritten after an adversarial review of v1 found it non-functional
> in several ways (see "What changed from v1" at the end). This version fixes
> those, and also cuts scope per that review's overengineering finding.

## Scope

This spec covers a host-side supervisor around the existing `bin/anatta` run
loop that:

1. Detects when a self-edit has broken Anatta's own dispatch loop (not
   routine in-loop eval errors — those already self-heal via the existing
   `result :error` feedback path in `anatta-step`).
2. Checkpoints via git (mostly free — already happens per `anatta-persist-to`
   and `anatta-log-persist` call) and rolls `agent/` back to the commit from
   just before the step that broke it.
3. Re-seeds the agent with a plain-text account of what broke, so the next
   turn can react to it instead of repeating the same self-edit blind.

This directly answers the open question already in the README: *"Recovery
path if a self-edit breaks the agent's own eval/dispatch loop from the
inside — current answer is external (daemon restart + git), not anything
defended in Elisp itself."*

The protected surface is deliberately exactly three things, matching how
narrow the actual failure class is: **the eval mechanism** (is the daemon
even responding), **the loop** (`anatta-run`/`anatta-step`), and **the log**
(`anatta-log` and its append/persist functions). Nothing else needs
protecting — any other self-edit (a broken helper, a bad capability file) is
already self-healing via the existing in-loop error path, or fixable by a
human running `git checkout` by hand. This spec adds nothing for that case.

Explicitly **out of scope**: any change to `anatta-log.el`'s entry schema
(the rollback record is a plain `(:role user :content STRING)` entry, the
same shape existing user turns use); detecting an agent that's merely
unproductive (fast no-op turns, repeated errors) rather than broken — that's
bounded by `max-iter` already, same as today; any sandboxing beyond the
existing Docker container.

## Background

The core safety property Anatta already has: every self-edit
(`anatta-persist-to`) and every turn (`anatta-log-persist`) is git-committed
inside `agent/`, which lives in the same repo as `.git` (see
`docker-compose.yml`'s whole-repo mount). So "checkpoint" already exists at
per-step granularity — the missing piece is *detecting* breakage and *acting*
on those checkpoints automatically, from outside the process that could be
broken.

Design principle (matches the project's existing Docker isolation stance —
the agent already has no host access): **the supervisor must not run inside
anything the agent can modify.** Its logic lives only in `bin/`, a directory
the agent's own git commits never touch (it only ever `git add`s inside
`agent/` — see `anatta-persist-to` and `anatta-log-persist`) and that a
rollback's `git checkout -- agent/` cannot revert.

**A constraint this spec had to design around: Emacs is single-threaded.**
While `anatta-step` is blocked inside a synchronous `call-process` HTTP call
to the LLM provider (see `anatta-providers.el`), the daemon cannot service a
*second*, concurrent `emacsclient` connection at all — it will simply queue
until the first request finishes. A design that polls a separate health
probe *while* a long `anatta-run` call is in flight (an earlier draft of this
spec did this) cannot distinguish "the daemon is busy with a slow but
perfectly fine LLM call" from "the daemon is wedged," because both look
identical from outside: no response. The only signal that's actually
meaningful is **whether the one call the supervisor itself is waiting on
returns within a generous timeout** — so the health check has to be the
*step call itself*, not a separate concurrent probe.

## Design

### The unit of work: one step, one timeout, one verdict

`bin/anatta` no longer makes a single `(anatta-run $max_iter)` call. It calls
`anatta-run` for exactly **one step at a time**, sequentially, each wrapped
in a timeout, and inspects the result:

```elisp
(progn (anatta-run 1) (list :done anatta-loop-done-p))
```

Calling with `N=1` every time (rather than some larger/configurable batch
size) is deliberate, not just the cautious default: `anatta-run` unconditionally
resets `anatta-loop-done-p` to `nil` at the start of every call, so the
supervisor must read that flag back *in the same round trip* as the call that
set it, before the next call resets it again — fixed by `(list :done
anatta-loop-done-p)` in the same `progn`. A larger batch size would also make
"how many steps actually ran" ambiguous if the agent ever redefines
`anatta-run` itself (a thing it's explicitly encouraged to do) to not consume
exactly N steps per call; asking for exactly one step per call sidesteps that
ambiguity entirely rather than trying to solve it.

No real OS `timeout(1)`/`gtimeout` binary is assumed to exist (it doesn't on
plain macOS). The timeout is implemented by backgrounding the
`docker compose exec` client process and polling it:

```sh
docker compose exec -T anatta emacsclient --eval "$expr" >"$outfile" 2>"$errfile" &
cli_pid=$!
waited=0
while kill -0 "$cli_pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
  sleep 1; waited=$((waited + 1))
done
if kill -0 "$cli_pid" 2>/dev/null; then
  kill -9 "$cli_pid" 2>/dev/null || true
  wait "$cli_pid" 2>/dev/null || true   # see note below — this `|| true` is load-bearing
  # timed out — daemon likely wedged
fi
```

**Both `kill` and `wait` above must be explicitly guarded with `|| true`
(or equivalent), not left bare.** This script runs under `set -e`, and a
bare `wait` on a process that exited nonzero (137 after `SIGKILL`, or any
nonzero `emacsclient` exit) aborts the *calling function* immediately, at
the `wait` line itself — before any subsequent line, including the `echo
"UNHEALTHY: ..."` that reports the failure, ever executes. This was caught
by review (reproduced directly, not theoretically): an earlier draft of
this design fixed the exact same `set -e` hazard for `$(cmd)` assignments
but missed that it applies equally to any bare fallible command whose exit
status is inspected or discarded afterward — `wait`, `git checkout`, `git
rm`, `docker compose restart`, etc. The fix is the same principle applied
consistently: every fallible command in this design is either the
condition of an `if`/`while`/negated with `!` (all exempt from `set -e`),
or explicitly suffixed with `|| true` / `|| var=""` / `|| var=$?`. A
correct status-capturing pattern that stays `set -e`-safe is `status=0;
wait "$cli_pid" || status=$?` — never a bare `wait` followed by a separate
`status=$?` line, which is one line too late.

Important caveat this must be documented, not silently assumed away: killing
`cli_pid` only kills the *host-side client* process. It does **not** interrupt
whatever the daemon is still evaluating server-side — Emacs keeps running the
wedged call regardless of whether anything is still listening for its
result. This is fine, because the only recovery path after a timeout is
always "restart the daemon" (below), never "try the same daemon again."

After the call returns (or is killed), the verdict is one of exactly three
things:

- **`DONE`** — call returned in time, output contains `:done t`. Stop, success.
- **`CONTINUE`** — call returned in time, output contains `:done nil`. Loop again.
- **`UNHEALTHY: <reason>`** — call timed out, `emacsclient` exited nonzero
  (covers a crashed daemon, or an elisp error escaping uncaught to the
  top — see below), or the output matched neither `:done t` nor `:done nil`
  (covers a corrupted `anatta-log` making even `anatta-log-append` itself
  throw an unhandled error, which is *not* inside `anatta-step`'s own
  `condition-case` — that only wraps the agent's own form, not the log
  bookkeeping around it).

This single check is strictly more general than an earlier draft's separate
"is `anatta-run` still `fboundp`/`functionp`" probe: that probe only caught
`(fset 'anatta-run 5)`-style damage, a case no model plausibly produces on
its own, while missing the actual failure modes that matter (an infinite
loop inside a redefined function, which is still `functionp`, or a broken
`anatta-log-append`). Checking "did the real call the supervisor needed
anyway behave as expected" catches all of those instead of guessing at
specific corruption shapes in advance.

### Tracking "last good"

Before each step call, capture `last_good=$(git rev-parse HEAD)`. If the step
comes back `CONTINUE` or `DONE`, that's discarded and re-captured before the
next call. If it comes back `UNHEALTHY`, `last_good` is — by construction —
the commit from immediately before *this* step ran, i.e. before whatever the
agent's current-turn eval did (including any `anatta-persist-to` calls that
turn made, which commit immediately, before the turn's `anatta-log-persist`
call, before the *next* step is what actually hangs/breaks). This is exactly
the state we want to revert to: no extra bookkeeping needed beyond
re-capturing one variable each loop iteration.

### Rollback

Once a step comes back `UNHEALTHY: <reason>`:

1. Diagnostics, captured before any mutation: `git diff --name-only
   "$last_good" HEAD -- agent/` (changed files) and `git diff "$last_good"
   HEAD -- agent/` truncated to 4000 chars (likely-culprit diff).
2. **Remove files added since `$last_good`.** `git checkout "$last_good" --
   agent/` only restores paths that existed at `$last_good` — it does
   **not** delete a file the broken turn added via `anatta-persist-to` (e.g.
   a new `bad-capability.el`), since checkout of a pathset only touches paths
   present in the target commit. So first: `git diff --name-only
   --diff-filter=A "$last_good" HEAD -- agent/` (added paths), `git rm -q -f`
   each one, *then* `git checkout "$last_good" -- agent/` to restore every
   modified/deleted path's content.
3. `docker compose restart anatta` — required because a live image's
   in-memory function definitions don't un-corrupt themselves just because
   the files on disk changed; `entrypoint.sh` re-runs on restart and reloads
   `log.el` from the now-restored file.
4. Poll for real readiness, not mere connectivity: `emacsclient --eval
   "(and (fboundp 'anatta-log-append) (boundp 'anatta-log))"` until it
   returns `t` (bounded retries, e.g. 30 x 1s). Polling for a trivial
   `(quote ok)` response instead would risk winning the race against
   `entrypoint.sh`'s own `require`/`anatta-log-load` still being in flight,
   and then the next step failing on a `void-function` that has nothing to
   do with the original break.
5. Write the diagnostic record to a file under a scratch dir
   (`.anatta-run/`, gitignored, inside the repo so the bind-mounted container
   can see it too) and have Emacs read it back with `insert-file-contents`,
   rather than inlining arbitrary diff text into an `--eval` argv string —
   unbalanced quotes/parens in the diff (agent-authored code, by
   definition) would otherwise risk breaking the elisp reader, the same
   `ARG_MAX`/embedding reasoning `anatta-provider-request` already uses a
   tmpfile for. Append the record with `anatta-log-append`, then write
   `log.el` directly — **not** via `anatta-log-persist`:
   `(progn (anatta-log-append (list :role 'user :content (with-temp-buffer
   (insert-file-contents "<path>") (buffer-string)))) (let ((path
   (expand-file-name "log.el" anatta-agent-dir))) (with-temp-file path
   (prin1 anatta-log (current-buffer)))))`. Using `anatta-log-persist` here
   was tried and is wrong, confirmed by actually running this: step 2's
   `git checkout`/`git rm` already **stage** the revert in the index (a
   targeted `git checkout <commit> -- <paths>` updates the index, not just
   the working tree) without committing it. If `anatta-log-persist` then
   ran its own `git commit` here, that commit captures the *entire* index —
   not just the `log.el` it `git add`ed — so the still-staged revert gets
   silently absorbed into a commit labeled `persist: log`, and step 6's
   intended `rollback: ...` commit finds nothing left and never happens.
   Writing the file without committing avoids this entirely.
6. `git add agent/ && git commit -m "rollback: reverted to <sha8> after
   health check failure"` — the one commit for the whole operation: the
   restored/removed files from step 2 and the freshly written `log.el` from
   step 5, together, under a message that actually says what happened.

Record content (plain text, not JSON — the model reads it as text either
way, and this stays in the codebase's existing "plain elisp/`format`, not a
second serialization format" idiom):

```
ROLLBACK: reverted agent/ to commit <sha8>. Health check failure: <reason>.
Files reverted: <changed files>
Diff (truncated to 4000 chars):
<diff>
Analyze this failure and propose a safer modification. Do not repeat the
change that caused it.
```

### Wiring into `bin/anatta`

- `ANATTA_STEP_TIMEOUT` (default 120s) — per-step timeout. Generous on
  purpose: it has to comfortably exceed the slowest plausible LLM round trip,
  since (per the single-threaded constraint above) there is no way to tell
  "slow but fine" from "wedged" except by how long it takes.
- `ANATTA_MAX_ROLLBACKS` (default 3) — caps total rollbacks per invocation.
  Exceeding it stops the run and prints the last diagnostic to the operator
  instead of looping forever against a self-reintroduced bad edit — same
  "hand control back to a human" backstop `max-iter` already provides for
  the provider-failure case in the original spec, applied to this failure
  class.
- `ANATTA_MAX_ITER` (default 50, unchanged) — now counts supervisor
  iterations (one step call each) rather than steps guaranteed to have run,
  since a redefined `anatta-run` could in principle do something other than
  exactly one step per call. Documented as an accepted, honest
  simplification rather than something this spec tries to solve.
- `trap 'docker compose down >/dev/null 2>&1' EXIT` replaces the old
  script's manual `docker compose down` at the end, so the container doesn't
  get left running if `set -e` fires mid-loop (e.g. on hitting the rollback
  budget).

## Testing plan

None of this needs a real provider or API key — the step timeout, rollback,
and CLI wiring all operate on daemon/git/filesystem state, not on what an
LLM actually says. One integration test, `test-recovery.sh` (repo root,
sibling of `smoke-test.sh`, same "real container, no mocking of
docker/git/emacsclient" philosophy), covering both paths for real:

1. **Happy path.** Persist (via a real `anatta-persist-to` call, so it's
   committed and survives exactly like a real capability would) a stub
   `anatta-provider-request` that returns `(anatta-done)` on its first call.
   Run the supervisor loop with `ANATTA_MAX_ITER=3`; assert it reaches `DONE`
   on the first iteration, no rollback fires.
2. **Recovery path.** Before starting the loop, persist a *second* stub
   `anatta-provider-request` (again via real `anatta-persist-to`, so this
   becomes part of the committed "good" baseline the way any prior capability
   would) that returns `(defun anatta-step () (while t))` wrapped in
   `anatta-persist-to` on its first call — i.e., simulating exactly the
   motivating scenario: a turn that persists a genuinely loop-breaking
   redefinition. Record `last_good` before starting. Run the supervisor loop
   with a short `ANATTA_STEP_TIMEOUT` (e.g. 5s): assert the first step comes
   back `UNHEALTHY: ... timed out`, assert rollback fires (new `rollback:`
   commit appears, `bad-step.el`-equivalent file is gone from `agent/`,
   `anatta-log` — read back via `emacsclient --eval '(pp-to-string
   anatta-log)'` — contains a `ROLLBACK:` entry), and assert the daemon is
   healthy again afterward (a plain `(+ 1 1)` eval succeeds).

This intentionally tests the exact functions `bin/anatta` calls (not
duplicated/reimplemented probe logic in the test), and injects the break via
a real, persisted, restart-surviving-until-reverted self-edit rather than an
in-memory-only `fset` that a subsequent `docker compose restart`/`down` would
have wiped regardless of whether rollback code did anything at all.

## Open questions

- **Per-step timeout tuning.** 120s is a guess at "comfortably longer than
  the slowest plausible LLM call." Too short risks false-positive rollbacks
  on a merely slow-but-fine response; too long delays real recovery. Left as
  an env var, not resolved here.
- **What counts as "last good"** is exactly "the commit before the step that
  just failed" — this does not walk further back if an earlier step's damage
  only manifests several steps later (e.g. a helper redefined at step k that
  isn't called, and thus doesn't break anything, until step k+5). Not
  addressed here.
- **Host/container git contention.** The daemon commits as whatever user the
  container runs as, over the same bind-mounted working tree the host's
  `git` commands (`checkout`, `rm`, `add`, `commit`, `rev-parse`) operate on
  between steps. Concurrent access is naturally serialized here (the
  supervisor never runs a host git command while a step call is in flight),
  but ownership/permission mismatches between container and host processes
  touching the same files are a known rough edge, not solved by this spec.

## What changed from v1

An adversarial review (Opus) of the first draft of this spec/plan found it
close to non-functional: no `timeout` binary on this machine, `set -e` +
`$(...)` assignment silently aborting the supervisor on the first unhealthy
result, a per-step call with no timeout at all (so the one failure mode this
whole feature exists for — a hang — was never actually caught), tests that
broke state in-memory and then restarted/rebuilt the container before the
code under test ever ran, and `git checkout` not deleting files added since
the target commit. It also correctly called the original structural
`fboundp`/`functionp` probe near-worthless (real damage a model would
plausibly cause mostly doesn't look like that) and the four-file,
three-test-script layout overengineered for a project this size. This
version replaces the separate probe with the step-call-timeout design above
(discovered while fixing the missing-timeout bug: Emacs's single-threadedness
means a *concurrent* probe can't work anyway, which is a stronger reason than
"it was buggy" — see "The unit of work" above), fixes the `set -e` and
added-file bugs, and collapses the implementation to one shared shell file
plus one real end-to-end test.
