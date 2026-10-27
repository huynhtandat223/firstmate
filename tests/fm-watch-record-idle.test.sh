#!/usr/bin/env bash
# Record idle verdict must take the existing quiet paused route without a ping.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-record-idle)
trap fm_test_cleanup EXIT
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/data/task"
printf 'window=test\nbackend=tmux\nharness=grok\n' > "$TMP_ROOT/home/state/task.meta"
printf 'Terminal call: required\n' > "$TMP_ROOT/home/data/task/brief.md"
touch "$TMP_ROOT/home/state/task.turn-ended"
# shellcheck source=bin/fm-watch.sh
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
. "$ROOT/bin/fm-watch.sh"
fm_backend_agent_state() { printf alive; }
watcher_capture() { WATCHER_CAPTURE=ready; }
fm_backend_composer_state() { printf empty; }
fm_run_timed() { case "$*" in *turn-end*) printf idle ;; *) return 0 ;; esac; }
turnend_send_ping() { fail 'idle sent a ping'; }
turnend_check_task task
[ "$TURNEND_VERDICT" = valid-paused ] || fail "idle returned $TURNEND_VERDICT: $TURNEND_WHY"
printf 'ok - idle record verdict is quietly paused\n'
