# anatta

A headless, self-modifying Elisp agent.

"Code mode" (Cloudflare/Anthropic, 2025) has agents write real code against
a typed API instead of emitting JSON tool-calls, because models are more
fluent in code than in synthetic tool-call schemas. Emacs can take this
further than a sandboxed script runner can: because Elisp is homoiconic and
Emacs is a live, introspectable runtime, there's no real boundary between
"calling a tool," "adding a new tool," and "rewriting the agent's own
control loop." A function is a function whether it's a tool the agent
invokes or the agent's own reasoning loop. So: run a headless Emacs process
as the agent's entire body. The LLM writes Elisp. That Elisp can call
tools, define new tools, or redefine the function that is currently driving
the agent's own loop — same mechanism (`defun`, `advice-add`, `eval`) for
all three.

The built-in capability surface is deliberately minimal — implicit eval of
whatever Elisp the model returns each turn, plus one predefined helper
(`anatta-persist-to`) for durably writing a new capability to disk. There's
no built-in `read`/`shell`/`grep`/etc. the way a typical agent harness
ships: Elisp already has that machinery natively (`with-temp-buffer`,
`shell-command`, `directory-files`, ...), so the agent is expected to write
those for itself, the first time it needs them.

Everything runs inside Docker with no host access, since an agent that can
rewrite its own control loop can also break it. Every self-edit (code and
the conversation log itself, which is plain Elisp data the agent can
inspect or rewrite) is git-committed, so recovery from a bad self-edit is a
`git checkout` away, not a rebuild.

## Status

A wired LLM loop, not just a feasibility spike (the original spike script
confirmed the core eval mechanism — defining functions, redefining them
live, writing/loading `.el` files from disk — and has since been removed:
the ERT suite and the real entrypoint check below cover strictly more of
the same ground). `agent/anatta-log.el`,
`agent/anatta-providers.el`, and `agent/anatta-loop.el` add a real
provider-driven loop on top of it: the conversation log is native elisp
data (not JSON), providers are swappable plists (Anthropic, OpenAI,
OpenRouter — active by default, since OpenRouter's API is OpenAI-compatible
and its provider plist reuses the OpenAI functions directly), and
the built-in capability surface is exactly two things — implicit eval
of whatever elisp the model returns each turn, and `anatta-persist-to`
for durably writing a new capability. Everything else is expected to be
elisp the agent writes for itself at runtime.

Two ways to run it:

- **As a CLI:** `bin/anatta "<task>"` starts the containerized daemon if
  needed, runs the task one step at a time (each step wrapped in a timeout,
  with automatic rollback if a step wedges the daemon — see "Open
  questions" and `bin/anatta-lib.sh`), prints the resulting log, exits.
  `smoke-test.sh` is a thin wrapper around this for a one-shot manual
  real-provider check.
- **Inside Emacs:** `(require 'anatta-loop)` in any running Emacs (headless
  daemon or your own interactive session), `setq anatta-agent-dir` to
  wherever you want the agent's workspace, then `M-x anatta-run` (or
  `C-u 5 M-x anatta-run` to cap it at 5 steps) drives the loop directly —
  watch `anatta-log` grow, eval into it yourself, no container required.

Run `OPENROUTER_API_KEY=<key> ./smoke-test.sh` for one real,
manually-verified turn. Unit tests for each piece run without any
network access — see `agent/tests/`.

## Layout

- `Dockerfile` / `entrypoint.sh` — headless Emacs daemon in a container.
- `docker-compose.yml` — bind-mounts the whole repo into the container at
  `/repo` (not just `./agent`), so `agent/`'s git commits can see `.git`,
  which lives at the repo root.
- `bin/anatta` — the CLI entrypoint (`bin/anatta "<task>"`).
- `bin/anatta-lib.sh` — the step-timeout and rollback functions `bin/anatta`
  uses to recover from a self-edit that breaks the loop mechanism itself;
  deliberately lives under `bin/`, never loaded into the Emacs image the
  agent controls, and outside the `agent/` subtree a rollback restores.
- `test-recovery.sh` — end-to-end check of the step-timeout/rollback path
  against the real container; no API key needed.
- `smoke-test.sh` — a one-shot manual real-provider check, thin wrapper
  around `bin/anatta`.
- `agent/` — `anatta-log.el` (the conversation log), `anatta-providers.el`
  (provider plists + HTTP transport), `anatta-loop.el` (system prompt, code
  extraction, the step/run loop), `agent/tests/` (ERT tests for all three).
  This is also where the agent's own persisted `log.el` and any
  self-authored capability files land at runtime.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — the design spec
  and implementation plan this codebase was built from.

## Open questions

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
- Deliberate "commit" boundary vs. live-editing the running image.
- No context-window/token-budget management yet — the log grows every step
  with no truncation or summarization.
- How to keep agent-authored capabilities organized as they accumulate.

## License

Apache License, Version 2.0 — see [`LICENSE`](LICENSE). Redistributing this
project or a derivative work requires carrying forward the attribution
notices in [`NOTICE`](NOTICE), per License Section 4(d).
