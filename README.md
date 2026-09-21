# anatta

A headless, self-modifying Elisp agent. See the design writeup at
[`../ideas/emacs-code-mode-agent-idea.md`](../ideas/emacs-code-mode-agent-idea.md)
for the full idea.

The premise: instead of an LLM emitting JSON tool-calls against a fixed
SDK ("code mode"), it writes Elisp directly into a live, headless Emacs
process. Because Emacs is homoiconic and fully introspectable at
runtime, there's no boundary between "calling a tool," "adding a new
tool," and "rewriting the agent's own control loop" — they're all just
`eval`.

Everything runs inside Docker with no host access, since an agent that
can rewrite its own control loop can also break it.

## Status

Spike-stage plus a wired LLM loop. `spike.sh` confirms the core eval
mechanism (see the first commit). `agent/anatta-log.el`,
`agent/anatta-providers.el`, and `agent/anatta-loop.el` add a real
provider-driven loop on top of it: the conversation log is native elisp
data (not JSON), providers are swappable plists (Anthropic/OpenAI), and
the built-in capability surface is exactly two things — implicit eval
of whatever elisp the model returns each turn, and `anatta-persist-to`
for durably writing a new capability. Everything else is expected to be
elisp the agent writes for itself at runtime.

Two ways to run it:

- **As a CLI:** `bin/anatta "<task>"` starts the containerized daemon if
  needed, runs the task, prints the resulting log, exits. `smoke-test.sh`
  is a thin wrapper around this for a one-shot manual real-provider check.
- **Inside Emacs:** `(require 'anatta-loop)` in any running Emacs (headless
  daemon or your own interactive session), `setq anatta-agent-dir` to
  wherever you want the agent's workspace, then `M-x anatta-run` (or
  `C-u 5 M-x anatta-run` to cap it at 5 steps) drives the loop directly —
  watch `anatta-log` grow, eval into it yourself, no container required.

Run `ANTHROPIC_API_KEY=<key> ./smoke-test.sh` for one real,
manually-verified turn. Unit tests for each piece run without any
network access — see `agent/tests/`.

## Running the spike

```sh
./spike.sh
```

## Layout

- `Dockerfile` / `entrypoint.sh` — headless Emacs daemon in a container.
- `docker-compose.yml` — bind-mounts the whole repo into the container at
  `/repo` (not just `./agent`), so `agent/`'s git commits can see `.git`,
  which lives at the repo root.
- `spike.sh` — the feasibility check above.
- `agent/` — where the agent's own `.el` files will live once it starts
  writing them.

## Open questions (from the idea doc)

- Recovery path if a self-edit breaks the agent's own eval/dispatch loop.
- Deliberate "commit" boundary vs. live-editing the running image.
- Whether code-mode's context-efficiency argument still holds once the
  tool list is agent-authored and growing.
- How to keep agent-authored capabilities organized as they accumulate.
