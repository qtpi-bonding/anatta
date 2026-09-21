#!/bin/sh
# Spike: does `emacsclient --eval` round-trip cleanly through a headless
# Emacs daemon running in the container? This is the whole feasibility
# question before wiring up an LLM loop.
set -e

docker compose build
docker compose up -d

echo "--- basic eval ---"
docker compose exec anatta emacsclient --eval '(+ 1 2)'

echo "--- defun + call (does the image actually gain a new function?) ---"
docker compose exec anatta emacsclient --eval \
  '(progn (defun anatta-greet (name) (format "hello, %s" name)) (anatta-greet "world"))'

echo "--- self-redefinition (redefine a function the agent already defined) ---"
docker compose exec anatta emacsclient --eval \
  '(progn (defun anatta-greet (name) (format "hi again, %s" name)) (anatta-greet "world"))'

echo "--- write a .el file from inside the image, load it back ---"
docker compose exec anatta emacsclient --eval \
  '(progn (with-temp-file "/repo/agent/scratch.el" (insert "(defun anatta-from-disk () 42)")) (load "/repo/agent/scratch.el") (anatta-from-disk))'

docker compose down
