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

Spike-stage. `spike.sh` confirms the core feasibility question: does
`emacsclient --eval` reliably round-trip code into a running headless
daemon, including redefining functions and writing/loading `.el` files
from disk? All four checks pass:

- basic eval
- `defun` + call a brand-new function
- redefine an existing function (self-modification, no restart)
- write a `.el` file from inside the container, `load` it, call it
  (confirms the persistence path through the `./agent` bind mount)

No LLM loop wired up yet.

## Running the spike

```sh
./spike.sh
```

## Layout

- `Dockerfile` / `entrypoint.sh` — headless Emacs daemon in a container.
- `docker-compose.yml` — bind-mounts `./agent` into the container as the
  agent's writable "genome" directory.
- `spike.sh` — the feasibility check above.
- `agent/` — where the agent's own `.el` files will live once it starts
  writing them.

## Open questions (from the idea doc)

- Recovery path if a self-edit breaks the agent's own eval/dispatch loop.
- Deliberate "commit" boundary vs. live-editing the running image.
- Whether code-mode's context-efficiency argument still holds once the
  tool list is agent-authored and growing.
- How to keep agent-authored capabilities organized as they accumulate.
