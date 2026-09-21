#!/bin/sh
set -e

emacs --daemon

# Keep the container alive so `docker exec` / `emacsclient` can reach the daemon.
tail -f /dev/null
