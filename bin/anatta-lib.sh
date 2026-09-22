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
    # direct repro, not a theoretical concern. `|| true` is what actually
    # prevents that; capturing $? afterward would be too late, since the
    # abort happens at `wait` itself.
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
#
# Every fallible command below is explicitly guarded (`|| true` /
# `|| var=""` / an `if`/`!` wrapper) -- this script runs under `set -e`,
# and a bare fallible command, even one whose result is discarded or
# captured afterward, aborts the whole function immediately (same hazard
# as anatta_run_step's `wait`, above). Only the steps whose failure should
# actually stop the rollback (the checkout, the readiness wait, the log
# append) are allowed to `return 1`, and each does so explicitly rather
# than via an uncontrolled `set -e` abort.
anatta_rollback() {
  last_good="$1"
  reason="$2"
  service="$3"

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

  container_recfile="/repo/${recfile#./}"
  if ! docker compose exec -T "$service" emacsclient --eval "(progn
    (anatta-log-append (list :role 'user :content
      (with-temp-buffer (insert-file-contents \"${container_recfile}\") (buffer-string))))
    (anatta-log-persist))" >/dev/null; then
    echo "anatta_rollback: failed to append diagnostic log entry" >&2
    rm -f "$recfile"
    return 1
  fi

  rm -f "$recfile"
  git add agent/
  git commit -q -m "rollback: reverted to $(git rev-parse --short "$last_good") after health check failure" || true
}
