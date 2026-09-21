# LLM Loop, Providers, and the Elisp-Native Log

## Scope

This spec covers exactly three things:

1. A **provider abstraction** for talking to LLM APIs (Anthropic and OpenAI to
   start).
2. The **turn loop** that wires a provider to the already-proven Emacs eval
   mechanism (see `spike.sh` / the first commit).
3. The **conversation log**, represented natively as elisp data rather than
   JSON/a database.

Explicitly **out of scope**: any built-in tool beyond eval + one durable-write
helper (the agent builds everything else itself at runtime, per the original
idea doc); any sandboxing beyond the Docker container already in place; any
REPL/UI; any multi-session or concurrency support; any authentication/secrets
management beyond reading an API key from an environment variable.

## Background

Full concept (see the repo README): a headless Emacs process is the
agent's entire body, and because Elisp is homoiconic and Emacs is fully
introspectable at runtime, there's no boundary between "calling a tool,"
"adding a new tool," and "rewriting the agent's own control loop" — all
three are just `eval`.

Proven so far (`spike.sh`, first commit): a headless Emacs daemon reliably
round-trips `emacsclient --eval`, including redefining its own functions and
writing/loading `.el` files from disk. Nothing here changes that mechanism —
this spec is purely about what calls `emacsclient --eval` and what it's
called with.

`gait` (`/Users/aicoder/Documents/systematic-action/concordium/gait`) is
**very rough inspiration only** for two narrow things:

- Its `Provider` trait shape (`stream(system, messages, tools) → chunks`,
  `provider/model` config string, API key resolved from env) — the idea of a
  small, swappable provider abstraction, not its actual streaming/chunk
  machinery.
- Committing durable state to git after each unit of work.

Everything else in gait — the protobuf event log, projections, sealed
brain/spine/hand processes, permission gate, dozen built-in tools, workflow
DAG runner — is **not** being replicated. Anatta's log is a plain elisp list
persisted with `prin1`/`read`, not an append-only protobuf log with
mutation/redaction semantics. Anatta's containment is the Docker container
built in commit 1, not kernel-level Seatbelt/Landlock sealing per tool call.
Anatta has exactly two built-in capabilities (implicit eval of every turn's
code, and one helper function for durable writes) instead of gait's dozen
`Tool` implementations — new capabilities are elisp the agent writes for
itself, not new Rust structs.

## Component 1: Providers (`anatta-providers.el`)

A **provider** is a plist describing how to talk to one LLM API:

```elisp
(:name "anthropic"
 :api-base "https://api.anthropic.com/v1/messages"
 :api-key-env "ANTHROPIC_API_KEY"
 :model "claude-sonnet-5"
 :build-request  #'anatta-anthropic-build-request   ; (log system-prompt) -> JSON string
 :parse-response #'anatta-anthropic-parse-response)  ; JSON string -> assistant text string
```

`anatta-active-provider` selects which provider plist is in effect (a single
global var, not a runtime-negotiated registry — switching providers means
`setq`-ing this and reloading, consistent with "everything else the agent can
build" if it wants more).

### The JSON boundary

Every provider API speaks JSON over HTTP. Emacs has `json-encode` and
`json-parse-string` built in — no external library. What differs per
provider is only the *shape* of the request/response envelope (Anthropic's
`messages` array + `system` field vs. OpenAI's `messages` array with a
`system`-role message inline, etc.); the payload this system actually cares
about is a single string — the assistant's response text — which is expected
to itself be (or contain) an elisp form. The provider's `:build-request` and
`:parse-response` functions are the only place that JSON shape-specific code
lives; everything upstream and downstream of them deals in plain elisp
strings/plists.

`anatta-provider-request(log, system-prompt)`:

1. Look up `anatta-active-provider`.
2. Call its `:build-request` with `log` (already converted to the provider's
   message-array shape by `anatta-log-to-provider-messages`, see Component
   2) and `system-prompt`, producing a JSON string.
3. POST it via `curl` as a subprocess (`call-process`), not `url.el` —
   simpler and more predictable in a headless container: no proxy/cookie
   state, easy to pass the API key as a header without it touching Emacs's
   URL cache. The API key is read from the env var named in `:api-key-env`
   at call time, never written into the log or persisted to disk. The JSON
   body is written to a temp file first and sent via `curl --data-binary
   @<tmpfile>`, **not** passed as a literal argv string — the log (and thus
   the request body) grows every turn, and an argv-string body risks
   hitting the OS's `ARG_MAX` well before the log gets large.
4. Call `:parse-response` on the response body, producing the assistant's
   raw text.
5. Return that text (a plain string) to the caller.

Network/HTTP failures (non-2xx, curl exit != 0, malformed JSON) are caught
here and surfaced as a `(:error ...)` value rather than a raised condition —
see Component 3's error handling for how the loop reacts.

## Component 2: The Log (`anatta-log.el`)

`anatta-log` is a global elisp variable: a list of plists, oldest first.

```elisp
(:role user      :content "add a function that greets by name")
(:role assistant :code "(defun greet (n) (format \"hi %s\" n))")
(:role result     :value "greet")                 ; successful eval
(:role result     :error "Symbol's function definition is void: foo")  ; failed eval
```

Functions:

- `anatta-log-append(entry)` — append `entry` to the **tail** of
  `anatta-log` (e.g. `(setq anatta-log (append anatta-log (list entry)))`,
  or maintain a separate reversed accumulator internally if append's O(n)
  cost ever matters). This is called out explicitly because elisp's `push`
  prepends — a literal "push a plist onto the log" reading would silently
  produce newest-first ordering and corrupt
  `anatta-log-to-provider-messages`'s output.
- `anatta-log-to-provider-messages(log)` — map `anatta-log` into the message
  array shape a provider's `:build-request` expects (role + content pairs;
  `result` entries are folded into the message stream as a synthetic
  user/tool-role message so the model sees its own eval output on the next
  turn).
- `anatta-log-persist()` — `prin1` the current `anatta-log` to
  `agent/log.el` (inside the existing bind-mounted `agent/` dir), then `git
  add` + `git commit` in that directory. Runs after every step.
- `anatta-log-load()` — on startup, if `agent/log.el` exists, `read` it back
  into `anatta-log`; otherwise start with an empty log plus one seeded user
  turn (the initial task).

The log is an ordinary mutable global. The agent's own eval'd code can
`setq`/`push`/`delete` against `anatta-log` directly — there is no API
boundary preventing it from editing its own history, by design (this was
the explicit ask: the conversation is data, and self-modification applies to
it the same as to any other function). The persistence + git-commit step is
the recovery mechanism for that, not a guardrail: a self-inflicted history
mangle is a `git checkout` away from repair, same safety net as the code
side.

## Component 3: The Loop (`anatta-loop.el`)

### System prompt

`anatta-system-prompt` is a string constant. It must communicate:

1. This is a live Emacs process, not a disposable sandboxed script runner —
   functions and variables it defines now exist on every later turn.
2. Its own conversation history is the `anatta-log` variable, and it's
   allowed to inspect, prune, or rewrite it directly via eval.
3. The calling convention: respond with **exactly one** elisp form per turn,
   inside a single fenced ```elisp block. (`anatta-extract-code` below parses
   the first such block; a response with none or with prose-only text is
   treated as a malformed turn — see error handling.)
4. `anatta-persist-to(path, form-string)` is predefined and available: it
   writes `form-string` to `path` under `agent/`, `load`s it (so it takes
   effect immediately), and git-commits it — this is the durable-capability
   path, contrasted with plain eval which only affects the running image
   until the daemon restarts.
5. It is running inside a disposable Docker container with a git-backed
   history of every change it makes to itself, and should act with real
   agency rather than hedging — mistakes are recoverable, not catastrophic.

The exact wording is an implementation-time task, not something this spec
pins down further.

### Functions

- `anatta-extract-code(text)` — regex-extract the content of the first
  ```elisp fenced block in `text` as a **string**. Returns `nil` if none
  found (see error handling). Any prose in `text` outside that fenced block
  (reasoning, commentary) is intentionally discarded — not logged in any
  field. This is a deliberate minimalism choice, not an oversight: the log
  only ever holds code and eval results, never freeform narration, so the
  agent's future turns see exactly what happened, not what it said about
  what happened.
- `anatta-read-single-form(code-string)` — `read` exactly one Lisp object
  from `code-string`, then check whether any non-whitespace text remains
  after it. If so, this is a protocol violation (the system prompt requires
  *exactly one* form) and the function returns an error rather than
  silently evaluating only the first form or silently `progn`-ing every
  form found — the model gets clear, visible feedback that it broke the
  one-form convention instead of a silent partial-execution.
- `anatta-step()` — one turn:
  1. `anatta-provider-request(anatta-log, anatta-system-prompt)` → raw text
     (or an error value).
  2. If it was an error: append a `(:role result :error ...)` entry
     summarizing the provider failure, persist, return — no eval attempted
     this turn (see error handling for the retry/stop policy).
  3. `anatta-extract-code` on the text. If `nil`: append a `(:role result
     :error "no elisp block found")` entry, persist, return.
  4. `anatta-read-single-form` on the extracted string. If it reports a
     multiple-forms violation: append a `(:role result :error "expected
     exactly one form, got extra trailing content")` entry, persist,
     return — no eval attempted.
  5. Append `(:role assistant :code <extracted-text>)` to the log (the raw
     string, for the record — read/eval operate on the parsed form).
  6. `condition-case`-wrapped `eval` of the parsed form. Append
     `(:role result :value <printed-result>)` on success or `(:role result
     :error <error-message>)` on failure.
  7. `anatta-log-persist()`.
- `anatta-run(&optional max-iter)` — calls `anatta-step` in a loop until
  either: the agent called `(anatta-done)` during its turn — a predefined
  function whose entire job is setting a global flag,
  `anatta-loop-done-p`, which `anatta-run` checks after each step — or
  `max-iter` steps have run (default: some fixed cap, e.g. 50, matching
  gait's `max_iter` in spirit).

### Error handling

Two independent failure classes, both turned into log entries so the model
sees them on its next turn and can react — same feedback-loop principle as
gait's tool-result-on-error:

- **Provider/network failure** (bad key, timeout, non-2xx, malformed JSON
  response): logged as a `result :error` entry. No automatic retry inside
  `anatta-step` — the *next* call to `anatta-step` (i.e., the next loop
  iteration) naturally retries by trying the provider again with the error
  now visible in context. If it fails repeatedly, `anatta-run`'s `max-iter`
  cap is the backstop that returns control to the human operator rather than
  spinning forever against a broken key.
- **Eval failure** (bad elisp, missing symbol, runtime error in agent-authored
  code): caught by `condition-case` inside `anatta-step`, logged as a
  `result :error` entry with the condition's error message. This is
  expected, routine behavior, not a fault — it's how the agent learns a
  capability it wrote is broken and fixes it next turn.

Neither failure class stops `anatta-run` early on its own; only reaching
`anatta-done` or `max-iter` does. This is a deliberate simplification: v0
has no distinction between "recoverable" and "fatal" errors. That
distinction is listed as an open question below.

### What this spec does not defend against

If the model's eval'd code redefines `anatta-step` or `anatta-run` itself
badly enough to break the loop from the inside, there is no in-image
recovery — the fix is restarting the Emacs daemon, which re-`load`s from the
last git-committed `.el` files under `agent/` (ground truth on disk, not
whatever's currently `defun`'d in the crashed image). This mirrors the
original idea doc's open question about a frozen "immune system" function;
this spec's answer for v0 is "the immune system is external: daemon restart
+ git," not anything defended in elisp itself.

## Testing plan

Before any real provider call: stub `anatta-active-provider`'s
`:build-request`/`:parse-response` (or `anatta-provider-request` directly)
to return canned elisp-form strings with no HTTP involved. Verify with this
mock: log grows correctly across several steps, a deliberately malformed
form produces an `:error` entry and the loop continues, `anatta-persist-to`
writes+loads+commits correctly, `anatta-run` stops at `max-iter` and at
`anatta-done`. Only after those pass, wire in a real provider (Anthropic
first) and run one real end-to-end turn by hand before trusting `anatta-run`
unattended.

## Open questions

- **No context-window/token-budget management.** `anatta-log` grows every
  step with no truncation, summarization, or windowing, capturing full
  code+result text. A real run can exceed the target model's context
  window well before hitting `max-iter` or `anatta-done` — this is a real
  functional failure mode (the provider call starts failing/truncating),
  not a cosmetic one, and v0 has no answer for it beyond "it'll eventually
  break and show up as a provider error."
- No distinction yet between a recoverable eval error (agent should just try
  again) and a fatal one (agent is stuck in a loop of the same failing form)
  — v0 relies on `max-iter` as the only backstop.
- No human-in-the-loop input path once `anatta-run` starts — the log is
  seeded with one task and the agent runs unattended until `anatta-done` or
  `max-iter`. Adding a way to inject a new user turn mid-run is deferred.
- `anatta-log-to-provider-messages`'s exact folding of `result` entries into
  the message stream (as a synthetic user turn vs. a provider-specific
  tool-result message type) is left to implementation; providers differ here
  and neither Anthropic nor OpenAI's tool-result conventions map cleanly
  onto "eval output of an arbitrary form," so this needs a concrete decision
  during implementation, not just at review time.
- Whether `anatta-log-persist`'s per-step git commit becomes a git-history
  wall of tiny commits that's unpleasant to read later, versus squashing at
  session end. Not addressed here; not a functional risk, just a possible
  ergonomics annoyance.
