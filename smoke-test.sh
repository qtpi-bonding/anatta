#!/bin/sh
# Manual smoke test: run ONE real turn against a real provider before
# trusting anatta-run unattended. Requires ANTHROPIC_API_KEY set on the
# host. Costs one real API call.
set -e
cd "$(dirname "$0")"

ANATTA_MAX_ITER=1 ./bin/anatta \
  "Define a function 'anatta-hello' that returns the string \"hello from anatta\", then call (anatta-done)."
