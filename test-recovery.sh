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
