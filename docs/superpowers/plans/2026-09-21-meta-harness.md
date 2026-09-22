# Meta-Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **v3** — supersedes two earlier versions, both found non-functional by
> adversarial review: v1 had no timeout on the actual step call (the one
> failure mode the feature exists for) plus several `set -e` hazards; v2 fixed
> those specific spots but the same `set -e` hazard recurred on bare `wait`/
> `git`/`docker` calls whose fallibility wasn't an assignment. v3's fix in
> Task 1 below guards every fallible command in `bin/anatta-lib.sh`, not just
> the ones the previous review happened to name. See "What changed from v1"
> at the end of the spec this plan implements.

**Goal:** Give `bin/anatta` an external supervisor that runs the agent one
step at a time, each wrapped in a timeout, detects when a step never returns
or returns something malformed (the loop/log mechanism itself broke), rolls
`agent/` back to the commit from before that step, and re-seeds the agent
with a plain-text account of what broke — without changing anything about
how routine in-loop eval errors are handled today.

**Architecture:** One shared shell library (`bin/anatta-lib.sh`) with two
functions — `anatta_run_step` (runs one `anatta-run 1` call with a portable
timeout, returns `DONE`/`CONTINUE`/`UNHEALTHY: <reason>`) and
`anatta_rollback` (git-restores `agent/`, restarts the daemon, injects a
diagnostic log entry). `bin/anatta` sources this library and drives the
loop. One integration test at the repo root exercises both functions against
the real container, injecting a real persisted breakage rather than an
in-memory one that a restart would wipe regardless of the code under test.

**Tech Stack:** POSIX `sh`, `docker compose`, `git`, `emacsclient`. No
changes to the existing ERT suite.

**Spec:** `docs/superpowers/specs/2026-09-21-meta-harness-design.md`

## Global Constraints

- No `timeout(1)`/`gtimeout` binary may be assumed to exist — implement
  timeouts by backgrounding + polling + `kill -9`.
- **Every fallible command must be explicitly guarded, not just fallible
  `$(cmd)` assignments.** This repo runs under `set -e`, which aborts the
  current function/script the instant *any* simple command exits nonzero —
  including a bare `wait` on a killed or nonzero-exit process, a bare `git
  checkout`/`git rm`/`docker compose restart`, not only `var=$(cmd)`. Guard
  with `|| true`, `|| var=""`, `|| var=$?` (never a bare `wait` followed by
  a separate `status=$?` line — that's one line too late), or by making the
  command the condition of an `if`/`while`/`!` (all exempt from `set -e`).
  This was gotten wrong twice already in earlier drafts of this exact
  plan — see the v3 note above — so treat it as the single highest-risk
  category of bug in this task's shell code, not a minor style point.
- All `docker compose exec` calls in scripts use `-T` (non-interactive).
- Diagnostic text passed into Emacs goes through a file under `.anatta-run/`
  (gitignored) read with `insert-file-contents`, never inlined into an
  `--eval` argv string.
- Supervisor logic lives only under `bin/` — never under `agent/`, which the
  agent's own commits write to and a rollback's `git checkout` restores.
- Tests use the real container (`docker compose`), never mocks of
  `docker`/`git`/`emacsclient` — matching `smoke-test.sh`'s existing
  philosophy. A test that injects breakage must do so via a real,
  git-committed `anatta-persist-to` call, not a bare in-memory `fset` that a
  subsequent restart would wipe independent of whether the code under test
  works.

---

### Task 1: Shared shell library — `anatta_run_step` and `anatta_rollback`

**Files:**
- Create: `bin/anatta-lib.sh`

**Interfaces:**
- Produces: `anatta_run_step <service> <timeout-secs>` — prints `DONE`,
  `CONTINUE`, or `UNHEALTHY: <reason>` to stdout; return code is 0 for
  `DONE`/`CONTINUE`, 1 for `UNHEALTHY`.
- Produces: `anatta_rollback <last-good-sha> <reason> <service>` — no
  stdout contract, side effects only (git checkout, container restart, log
  append, commit). Exits nonzero only if the daemon never comes back
  healthy after restart (bounded retries exhausted).

- [ ] **Step 1: Write `bin/anatta-lib.sh`**

```sh
#!/bin/sh
# Shared functions for bin/anatta's supervisor loop. Sourced, not executed
# directly. Deliberately lives under bin/, never under agent/ -- the agent's
# own commits only ever touch agent/, and a rollback's `git checkout --
# agent/` restores that subtree, so anything under bin/ is safe from both.

# anatta_run_step <service> <timeout-secs>
# Runs exactly one agent step and reports what happened. Calling with
# exactly 1 step every time (never a larger batch) sidesteps two problems:
# anatta-run resets anatta-loop-done-p to nil on every call, so the :done
# flag must be read back in the very same round trip that set it; and a
# redefined anatta-run (something the agent is explicitly encouraged to do)
# need not consume exactly N steps per call, so asking for exactly one
# avoids having to reason about how many steps a bigger N actually ran.
#
# No timeout(1)/gtimeout is assumed to exist. The timeout below only kills
# the *host-side* emacsclient process on expiry -- it cannot interrupt
# whatever the single-threaded Emacs daemon is still evaluating server-side.
# That's fine: the only recovery path after a timeout is always restarting
# the daemon (anatta_rollback, below), never reusing it.
anatta_run_step() {
  service="$1"
  secs="$2"

  mkdir -p .anatta-run
  outfile=$(mktemp .anatta-run/step-out.XXXXXX)

  docker compose exec -T "$service" emacsclient --eval \
    "(progn (anatta-run 1) (list :done anatta-loop-done-p))" \
    >"$outfile" 2>&1 &
  cli_pid=$!

  waited=0
  while kill -0 "$cli_pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$cli_pid" 2>/dev/null; then
    kill -9 "$cli_pid" 2>/dev/null || true
    # A bare `wait` on a killed (nonzero-exit) process trips `set -e` and
    # aborts this function before the echo below ever runs -- confirmed by
    # direct repro, not a theoretical concern. `|| true` on the whole
    # compound statement is what actually prevents that; capturing $?
    # afterward would be too late, since the abort happens at `wait` itself.
    wait "$cli_pid" 2>/dev/null || true
    rm -f "$outfile"
    echo "UNHEALTHY: step did not return within ${secs}s (daemon likely wedged)"
    return 1
  fi

  # Same `set -e` hazard as above: capture the exit status via `|| status=$?`
  # rather than a bare `wait` followed by `status=$?`, which would abort
  # this function on any nonzero exit before `status=$?` ever executes.
  status=0
  wait "$cli_pid" || status=$?
  out=$(cat "$outfile") || out=""
  rm -f "$outfile"

  if [ "$status" -ne 0 ]; then
    echo "UNHEALTHY: emacsclient exited ${status}: ${out}"
    return 1
  fi

  case "$out" in
    *':done t'*)
      echo "DONE"
      return 0
      ;;
    *':done nil'*)
      echo "CONTINUE"
      return 0
      ;;
    *)
      echo "UNHEALTHY: unexpected response: ${out}"
      return 1
      ;;
  esac
}

# anatta_rollback <last-good-sha> <reason> <service>
# Restores agent/ to <last-good-sha>, restarts the daemon so it reloads
# from the restored files, appends one diagnostic log entry via the
# freshly-restarted (trusted) log functions, and commits the result.
anatta_rollback() {
  last_good="$1"
  reason="$2"
  service="$3"

  # Every fallible command below is explicitly guarded (`|| true` /
  # `|| var=""` / an `if`/`!` wrapper) -- this script runs under `set -e`,
  # and a bare fallible command, even one whose result is discarded or
  # captured afterward, aborts the whole function immediately (same hazard
  # as anatta_run_step's `wait`, above). Only the steps whose failure should
  # actually stop the rollback (the checkout, the readiness wait, the log
  # append) are allowed to `return 1`, and each does so explicitly rather
  # than via an uncontrolled `set -e` abort.
  changed=$(git diff --name-only "$last_good" HEAD -- agent/) || changed=""
  diff_text=$(git diff "$last_good" HEAD -- agent/ | head -c 4000) || diff_text=""

  # git checkout of a pathset only restores paths present at last_good --
  # it does not delete a path added since then (e.g. a new capability file
  # the broken turn persisted). Remove those explicitly first.
  added=$(git diff --name-only --diff-filter=A "$last_good" HEAD -- agent/) || added=""
  if [ -n "$added" ]; then
    echo "$added" | while IFS= read -r f; do
      [ -n "$f" ] && { git rm -q -f -- "$f" || true; }
    done
  fi

  if ! git checkout "$last_good" -- agent/; then
    echo "anatta_rollback: git checkout failed, aborting rollback" >&2
    return 1
  fi

  docker compose restart "$service" >/dev/null 2>&1 || true

  i=0
  ready=0
  while [ "$i" -lt 30 ]; do
    check=$(docker compose exec -T "$service" emacsclient --eval \
      "(and (fboundp 'anatta-log-append) (boundp 'anatta-log))" 2>/dev/null) || check=""
    if [ "$check" = "t" ]; then
      ready=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done

  if [ "$ready" -ne 1 ]; then
    echo "anatta_rollback: daemon never became ready after restart" >&2
    return 1
  fi

  mkdir -p .anatta-run
  recfile=$(mktemp .anatta-run/rollback-record.XXXXXX)
  cat > "$recfile" <<EOF
ROLLBACK: reverted agent/ to commit $(git rev-parse --short "$last_good"). Health check failure: ${reason}.
Files reverted: ${changed}
Diff (truncated to 4000 chars):
${diff_text}
Analyze this failure and propose a safer modification. Do not repeat the change that caused it.
EOF

  # Deliberately NOT anatta-log-persist here (it does its own git commit).
  # git checkout/git rm above already staged the revert in the index but
  # left it uncommitted; if anatta-log-persist committed here, `git commit`
  # commits the *entire* index, not just the file it `git add`ed -- so that
  # commit would silently absorb the still-staged revert too, landing under
  # a misleading "persist: log" message, and the intended outer "rollback:
  # ..." commit below would then find nothing left to commit (confirmed by
  # running this for real: that's exactly what happened before this
  # comment existed). Writing the file directly, uncommitted, and letting
  # the one explicit commit below cover everything keeps it one commit with
  # the right message.
  container_recfile="/repo/${recfile#./}"
  if ! docker compose exec -T "$service" emacsclient --eval "(progn
    (anatta-log-append (list :role 'user :content
      (with-temp-buffer (insert-file-contents \"${container_recfile}\") (buffer-string))))
    (let ((path (expand-file-name \"log.el\" anatta-agent-dir)))
      (with-temp-file path (prin1 anatta-log (current-buffer)))))" >/dev/null; then
    echo "anatta_rollback: failed to append diagnostic log entry" >&2
    rm -f "$recfile"
    return 1
  fi

  rm -f "$recfile"
  git add agent/
  git commit -q -m "rollback: reverted to $(git rev-parse --short "$last_good") after health check failure" || true
}
```

- [ ] **Step 2: Shellcheck it (or eyeball if shellcheck isn't installed)**

Run: `command -v shellcheck >/dev/null && shellcheck bin/anatta-lib.sh || echo "shellcheck not installed, skipping"`
Expected: no errors (warnings about unquoted `$out` in the `case` are
acceptable — that variable is intentionally matched with glob patterns).

- [ ] **Step 3: Commit**

```bash
git add bin/anatta-lib.sh
git commit -m "feat: add step-timeout and rollback primitives for the meta-harness

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Wire the supervisor into `bin/anatta`

**Files:**
- Modify: `bin/anatta`

**Interfaces:**
- Consumes: `anatta_run_step`, `anatta_rollback` from Task 1.
- Produces: `bin/anatta "<task>"` — same usage and final printed-log output
  as before; new env vars `ANATTA_STEP_TIMEOUT` (default 120) and
  `ANATTA_MAX_ROLLBACKS` (default 3), alongside the existing
  `ANATTA_MAX_ITER` (default 50, now counting supervisor iterations rather
  than steps guaranteed to have run — see spec's "Wiring into bin/anatta").

- [ ] **Step 1: Rewrite `bin/anatta`**

```sh
#!/bin/sh
# anatta CLI: run one task against the agent's headless Emacs daemon,
# supervising it one step at a time so a self-edit that wedges the daemon
# gets rolled back automatically instead of hanging forever. Prints the
# resulting log, then exits.
#
# Usage: bin/anatta "<task>"
#   ANATTA_MAX_ITER=<n>       optional, supervisor iterations (default 50)
#   ANATTA_STEP_TIMEOUT=<n>   optional, seconds per step before treating the
#                             daemon as wedged (default 120)
#   ANATTA_MAX_ROLLBACKS=<n>  optional, rollbacks allowed before giving up
#                             (default 3)
set -e

if [ -z "$1" ]; then
  echo "usage: $0 \"<task>\"" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
. bin/anatta-lib.sh

export ANATTA_TASK="$1"
max_iter="${ANATTA_MAX_ITER:-50}"
step_timeout="${ANATTA_STEP_TIMEOUT:-120}"
max_rollbacks="${ANATTA_MAX_ROLLBACKS:-3}"

docker compose build
docker compose up -d
trap 'docker compose down >/dev/null 2>&1' EXIT

echo "--- running (max $max_iter steps, ${step_timeout}s/step timeout) ---"

ran=0
rollback_count=0

while [ "$ran" -lt "$max_iter" ]; do
  last_good=$(git rev-parse HEAD)
  result=$(anatta_run_step anatta "$step_timeout") || true
  ran=$((ran + 1))

  case "$result" in
    DONE)
      break
      ;;
    CONTINUE)
      ;;
    UNHEALTHY*)
      reason="${result#UNHEALTHY: }"
      if [ "$rollback_count" -ge "$max_rollbacks" ]; then
        echo "--- giving up: $max_rollbacks rollbacks exhausted ---" >&2
        echo "last diagnostic: $reason" >&2
        exit 1
      fi
      echo "--- step failed: $reason ---" >&2
      echo "--- rolling back to $(git rev-parse --short "$last_good") ---" >&2
      if ! anatta_rollback "$last_good" "$reason" anatta; then
        echo "--- rollback itself failed, stopping ---" >&2
        exit 1
      fi
      rollback_count=$((rollback_count + 1))
      ;;
    *)
      echo "--- unexpected result from anatta_run_step: $result ---" >&2
      exit 1
      ;;
  esac
done

echo "--- log ---"
docker compose exec -T anatta emacsclient --eval '(pp-to-string anatta-log)'
```

Note `entrypoint.sh` already does the agent-code bootstrap on container
start (`emacs --daemon` then `emacsclient --eval "(progn ... (anatta-log-load
(getenv \"ANATTA_TASK\")))"`, keyed on `ANATTA_TASK`, which `bin/anatta`
exports before `docker compose up -d`) — this plan makes no changes to
`entrypoint.sh` and deliberately does not duplicate that bootstrap inside
`bin/anatta`. This matters for `anatta_rollback`: its `docker compose
restart` re-runs `entrypoint.sh` from scratch, which reloads `log.el` from
the now-restored (last-good) file automatically, with zero extra code
needed on the rollback path.

- [ ] **Step 2: Confirm `entrypoint.sh` needs no changes**

Run: `cat entrypoint.sh`
Expected: it still does exactly `emacs --daemon`, the `emacsclient --eval`
bootstrap keyed on `ANATTA_TASK`, then `tail -f /dev/null` — unchanged from
before this plan. If it has drifted from this shape, stop and reconcile
before proceeding, since Task 1's `anatta_rollback` assumes a
`docker compose restart` alone is sufficient to get a fully reloaded,
task-seeded (or, on restart, already-logged) daemon back.

- [ ] **Step 3: Manual smoke check (no API key needed)**

```sh
ANATTA_MAX_ITER=1 ANATTA_STEP_TIMEOUT=10 ./bin/anatta "test task" 2>&1 | tail -20
```

Expected: it builds/starts the container, attempts one step (this will fail
with a provider error — no real API key configured in this shell — reported
as a normal in-loop `result :error`, i.e. `anatta_run_step` should report
`CONTINUE`, not `UNHEALTHY`, since the daemon itself is fine and answered
within the timeout), then prints `--- log ---` and the log contents, and the
container is stopped afterward (`docker compose ps` shows nothing running).

- [ ] **Step 4: Commit**

```bash
git add bin/anatta
git commit -m "feat: supervise anatta-run one step at a time with rollback

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: End-to-end recovery test and docs

**Files:**
- Create: `test-recovery.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `bin/anatta-lib.sh` (Task 1), `bin/anatta` (Task 2).
- Produces: nothing new — verifies the whole path together, documents it.

- [ ] **Step 1: Write `test-recovery.sh`**

Two bugs were found while actually running this test against the real
container (not just from reading it), both fixed in the version below:
`docker compose down` was being called between persisting the stub and
calling `anatta_run_step`, which would exec into a stopped container; and
the two-step recovery sequence's expectations were backwards — since
`anatta-persist-to` `load`s its redefinition immediately, the *first* step
(the one that does the persisting) completes normally as `CONTINUE`, and
only the *second* step actually calls the now-`(while t)` `anatta-step` and
hangs.

```sh
#!/bin/sh
# End-to-end test of the meta-harness: happy path (no breakage) and
# recovery path (a real, persisted, loop-breaking self-edit), both against
# the real container. No API key needed -- anatta-provider-request is
# stubbed via real, git-committed anatta-persist-to calls, not bare
# in-memory redefinitions that a restart would wipe regardless of whether
# the supervisor code works.
set -e
cd "$(dirname "$0")"
. bin/anatta-lib.sh

fail() { echo "FAIL: $1" >&2; docker compose down >/dev/null 2>&1 || true; exit 1; }

bootstrap='(progn
  (add-to-list (quote load-path) "/repo/agent")
  (setq anatta-agent-dir "/repo/agent/")
  (require (quote anatta-log))
  (require (quote anatta-providers))
  (require (quote anatta-loop)))'

echo "=== happy path ==="
docker compose up -d --build
anatta_wait_ready anatta || fail "daemon never became ready (happy path)"
docker compose exec -T anatta emacsclient --eval "$bootstrap" >/dev/null
docker compose exec -T anatta emacsclient --eval '(anatta-log-load "happy path test")' >/dev/null
docker compose exec -T anatta emacsclient --eval "(anatta-persist-to \"stub-done.el\"
  \"(defun anatta-provider-request (log system-prompt) (format \\\"\\\`\\\`\\\`elisp\\n(anatta-done)\\n\\\`\\\`\\\`\\\"))\")" >/dev/null

result=$(anatta_run_step anatta 30) || true
[ "$result" = "DONE" ] || fail "happy path expected DONE, got '$result'"
echo "happy path OK"

docker compose down >/dev/null 2>&1 || true
git checkout HEAD -- agent/ >/dev/null 2>&1 || true
git clean -fq agent/ >/dev/null 2>&1 || true

echo "=== recovery path ==="
docker compose up -d --build
anatta_wait_ready anatta || fail "daemon never became ready (recovery path)"
docker compose exec -T anatta emacsclient --eval "$bootstrap" >/dev/null
docker compose exec -T anatta emacsclient --eval '(anatta-log-load "recovery path test")' >/dev/null
docker compose exec -T anatta emacsclient --eval "(anatta-persist-to \"stub-break.el\"
  \"(defun anatta-provider-request (log system-prompt) (format \\\"\\\`\\\`\\\`elisp\\n(anatta-persist-to \\\\\\\"bad-step.el\\\\\\\" \\\\\\\"(defun anatta-step () (while t))\\\\\\\")\\n\\\`\\\`\\\`\\\"))\")" >/dev/null

last_good=$(git rev-parse HEAD)

# Step 1: the stub returns a form that persists a genuinely loop-breaking
# redefinition of anatta-step. anatta-persist-to loads it immediately, but
# the *currently executing* anatta-step call already passed the eval point
# and finishes normally -- only the *next* call to anatta-step is affected.
result=$(anatta_run_step anatta 20) || true
[ "$result" = "CONTINUE" ] || fail "expected CONTINUE after persisting the bad redefinition, got '$result'"

# Step 2: anatta-run calls anatta-step again, which is now (while t) -- hangs.
result=$(anatta_run_step anatta 5) || true
case "$result" in
  UNHEALTHY*) ;;
  *) fail "expected UNHEALTHY now that anatta-step is (while t), got '$result'" ;;
esac

anatta_rollback "$last_good" "$result" anatta || fail "anatta_rollback itself returned nonzero"

[ ! -f agent/bad-step.el ] || fail "bad-step.el survived rollback"

log_str=$(docker compose exec -T anatta emacsclient --eval "(pp-to-string anatta-log)") || fail "could not read back anatta-log after rollback"
case "$log_str" in
  *ROLLBACK:*) ;;
  *) fail "no ROLLBACK entry found in restored log" ;;
esac

new_head=$(git rev-parse HEAD)
[ "$new_head" != "$last_good" ] || fail "no new commit after rollback"
git log -1 --pretty=%s | grep -q '^rollback:' || fail "HEAD commit isn't a rollback commit"

healthy=$(docker compose exec -T anatta emacsclient --eval '(+ 1 1)') || true
[ "$healthy" = "2" ] || fail "daemon not healthy after rollback (got '$healthy')"

docker compose down
git checkout HEAD -- agent/ >/dev/null 2>&1 || true
git clean -fq agent/ >/dev/null 2>&1 || true
echo "recovery path OK"

echo "all meta-harness tests passed"
```

- [ ] **Step 2: Run it**

Run: `chmod +x test-recovery.sh && ./test-recovery.sh`
Expected: `all meta-harness tests passed`, no `FAIL` lines. If a `FAIL`
line appears, it names exactly which assertion failed and why — fix the
corresponding function in `bin/anatta-lib.sh` (not the test) unless the
test itself is wrong, and re-run.

- [ ] **Step 3: Update `README.md`**

Replace the first bullet of the "Open questions" section (currently
`"Recovery path if a self-edit breaks the agent's own eval/dispatch loop
from the inside — current answer is external (daemon restart + git), not
anything defended in Elisp itself."`) with:

```markdown
- ~~Recovery path if a self-edit breaks the agent's own eval/dispatch loop
  from the inside~~ — partially addressed: `bin/anatta` now runs the agent
  one step at a time, each wrapped in a timeout (`bin/anatta-lib.sh`). A
  step that never returns, or returns something malformed, triggers a
  rollback: `agent/` is restored to the commit from before that step, the
  daemon restarts, and one diagnostic log entry is appended describing what
  broke and why it was reverted. This catches a wedged/corrupted loop; it
  does not catch a self-edit that returns quickly without actually being
  broken (e.g. one that silently stops making progress without erroring or
  hanging) — that class is unprotected, same as before. See
  `docs/superpowers/specs/2026-09-21-meta-harness-design.md`.
```

Also add one line to the "Layout" section after the existing `bin/anatta`
entry:

```markdown
- `bin/anatta-lib.sh` — the step-timeout and rollback functions `bin/anatta`
  uses to recover from a self-edit that breaks the loop mechanism itself;
  deliberately lives under `bin/`, never loaded into the Emacs image the
  agent controls, and outside the `agent/` subtree a rollback restores.
```

- [ ] **Step 4: Commit**

```bash
git add test-recovery.sh README.md
git commit -m "docs: partially resolve meta-harness open question, add e2e recovery test

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```
