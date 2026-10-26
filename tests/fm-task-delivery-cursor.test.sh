#!/usr/bin/env bash
# The watcher must visit every recorded task under the aggregate API bound.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery-cursor)
mkdir -p "$TMP_ROOT/code/bin"
cp -a "$ROOT/bin/." "$TMP_ROOT/code/bin/"
cat > "$TMP_ROOT/code/bin/fm-task.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = deliver ]; then printf '%s\n' "$2" >> "$CURSOR_LOG"; fi
exit 0
SH
chmod +x "$TMP_ROOT/code/bin/fm-task.sh"
run_case() {
  local label=$1 dir pid n
  dir=$(make_case "$label")
  for n in a b c; do printf 'window=test:fm-a\nkind=secondmate\nharness=pi\nbackend=tmux\n' > "$dir/state/$n.meta"; done
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WATCH_HANDLING_SUCCESSOR=1 FM_FAKE_TMUX_WINDOW=test:fm-a FM_POLL=0.2 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 CURSOR_LOG="$dir/delivered" "$TMP_ROOT/code/bin/fm-watch.sh" > "$dir/out" 2>&1 &
  pid=$!
  sleep 7
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for n in a b c; do grep -qx "$n" "$dir/delivered" || return 1; done
}
run_case baseline || fail 'delivery cursor did not visit all tasks'
pass 'bounded watcher delivery visits all three task records'
S="[ \"\$task_delivery_processed\" = 1 ] || TASK_DELIVERY_LAST=''" R="TASK_DELIVERY_LAST=''" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$TMP_ROOT/code/bin/fm-watch.sh"
if run_case mutant; then fail 'cursor-reset mutation survived'; fi
pass 'full-list cursor case goes red when cursor resets every pass'
