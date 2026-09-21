#!/bin/sh
set -e

emacs --daemon

emacsclient --eval "(progn
  (add-to-list 'load-path \"/repo/agent\")
  (setq anatta-agent-dir \"/repo/agent/\")
  (require 'anatta-log)
  (require 'anatta-providers)
  (require 'anatta-loop)
  (anatta-log-load (getenv \"ANATTA_TASK\")))"

tail -f /dev/null
