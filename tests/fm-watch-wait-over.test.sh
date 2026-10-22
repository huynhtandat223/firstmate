#!/usr/bin/env bash
# tests/fm-watch-wait-over.test.sh - the watcher's wait-over alarm
# (bin/fm-watch.sh wait_over_tick, docs/configuration.md config/wait-over-minutes).
# One `check: wait-over <task> <m>m: <verb>: <note>` wake per wait when a ship or
# scout worker's newest status verb is paused, blocked or needs-decision and no
# newer status line or completed turn follows for the limit (default 45 minutes).
# Each case drives a real fm-watch.sh on stubbed status files and marker mtimes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-wait-over-tests)

MIN=60

set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Same signature fm-watch.sh's per-poll signal scan compares, so a fixture that
# was written by hand is not reported as a first-sight signal.
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(LC_ALL=C wc -c < "$1" | tr -d '[:space:]')
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

prime_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

# A worker record: meta, a status file with <lines>, and its suppressor.
make_task() {  # <state> <id> <kind> <status-text>
  local state=$1 id=$2 kind=$3 text=$4
  printf 'kind=%s\nbackend=tmux\n' "$kind" > "$state/$id.meta"
  printf '%s\n' "$text" > "$state/$id.status"
  prime_seen "$state/$id.status"
}

# Backdate <id>'s turn-ended or progress marker <minutes> ago, suppressor primed.
age_marker() {  # <state> <id> <turn-ended|progress> <minutes>
  local state=$1 id=$2 name=$3 minutes=$4 f
  f="$state/$id.$name"
  : > "$f"
  set_mtime $(( $(date +%s) - minutes * MIN )) "$f"
  prime_seen "$f"
}

stamped() {  # <verb> <minutes-ago> <note>
  printf '%s [at=%s]: %s' "$1" "$(( $(date +%s) - $2 * MIN ))" "$3"
}

watch_bg() {  # <state> <fakebin> <out> [env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 env "$@" "$WATCH" > "$out" &
}

# 0 when the watcher is still alive after one whole poll cycle, 1 when it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

# Acknowledge what the previous cycle left queued, so the next watcher starts
# clean instead of reporting the earlier wake again as a recovery.
ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

# Run a watcher until it either wakes (echo "woke") or finishes a quiet cycle (echo "quiet").
run_watcher() {  # <case-dir> [env assignments...]
  local dir=$1 pid
  shift
  ack_stopped_cycle "$dir/state" || true
  watch_bg "$dir/state" "$dir/fakebin" "$dir/watch.out" "$@"
  pid=$!
  if wait_poll_cycle "$dir/state" "$pid"; then
    reap "$pid"
    echo quiet
  else
    wait_for_exit "$pid" 100 || true
    echo woke
  fi
}

wake_count() {  # <out-file>
  grep -c '^check: wait-over ' "$1" 2>/dev/null || true
}

queued_wait_over_rows() {  # <state>
  FM_STATE_OVERRIDE="$1" "$DRAIN" 2>/dev/null | grep -c "$(printf '\tcheck\t')" || true
}

test_fires_once_for_one_wait() {
  local dir state out result
  dir=$(make_case wo-once); state="$dir/state"; out="$dir/watch.out"
  make_task "$state" worker1 ship "$(stamped paused 46 'waiting for the vendor reply')"
  result=$(run_watcher "$dir")
  [ "$result" = woke ] || fail "a paused wait over 45 minutes raised no wake"
  grep -E '^check: wait-over worker1 4[67]m: paused: waiting for the vendor reply$' "$out" >/dev/null \
    || fail "the wait-over wake reads wrong: $(cat "$out")"
  [ -f "$state/.wait-over-worker1" ] || fail "the reported wait left no marker"
  [ "$(queued_wait_over_rows "$state")" -eq 1 ] || fail "the wake was not queued exactly once"
  : > "$out"
  result=$(run_watcher "$dir")
  [ "$result" = quiet ] || fail "the same wait woke a second time: $(cat "$out")"
  [ "$(wake_count "$out")" -eq 0 ] || fail "the same wait printed a second wait-over wake"
  pass "a wait over 45 minutes wakes once, and the same wait never wakes again"
}

test_under_the_limit_is_quiet() {
  local dir state out result
  dir=$(make_case wo-under); state="$dir/state"; out="$dir/watch.out"
  make_task "$state" worker1 ship "$(stamped paused 10 'waiting for the vendor reply')"
  result=$(run_watcher "$dir")
  [ "$result" = quiet ] || fail "a ten-minute wait woke: $(cat "$out")"
  [ ! -e "$state/.wait-over-worker1" ] || fail "an unreported wait left a marker"
  pass "a wait under the limit raises no wake and leaves no marker"
}

test_each_wait_verb_fires() {
  local verb dir state out result
  for verb in blocked needs-decision paused; do
    dir=$(make_case "wo-verb-$verb"); state="$dir/state"; out="$dir/watch.out"
    make_task "$state" worker1 scout "$(stamped "$verb" 50 'the question')"
    result=$(run_watcher "$dir")
    [ "$result" = woke ] || fail "$verb wait over 45 minutes raised no wake"
    grep -E "^check: wait-over worker1 [0-9]+m: $verb: the question\$" "$out" >/dev/null \
      || fail "the $verb wake reads wrong: $(cat "$out")"
  done
  pass "paused, blocked and needs-decision waits each raise the wake, scout workers included"
}

test_other_verbs_and_kinds_raise_nothing() {
  local verb kind dir state out result
  for verb in working "done" failed captain-held handoff-needed resolved weirdword; do
    dir=$(make_case "wo-other-$verb"); state="$dir/state"; out="$dir/watch.out"
    make_task "$state" worker1 ship "$(stamped "$verb" 120 'old news')"
    result=$(run_watcher "$dir")
    [ "$result" = quiet ] || fail "a $verb line raised a wake: $(cat "$out")"
  done
  for kind in assistance secondmate; do
    dir=$(make_case "wo-kind-$kind"); state="$dir/state"; out="$dir/watch.out"
    make_task "$state" worker1 "$kind" "$(stamped paused 120 'long wait')"
    result=$(run_watcher "$dir")
    [ "$result" = quiet ] || fail "a $kind paused wait raised a wake: $(cat "$out")"
  done
  pass "other verbs, assistances and secondmates raise no wait-over wake"
}

test_newer_status_line_starts_a_new_wait() {
  local dir state out result
  dir=$(make_case wo-newline); state="$dir/state"; out="$dir/watch.out"
  make_task "$state" worker1 ship "$(stamped paused 100 'old wait')
$(stamped paused 10 'new wait')"
  result=$(run_watcher "$dir")
  [ "$result" = quiet ] || fail "a newer paused line within the limit still woke for the old wait: $(cat "$out")"
  dir=$(make_case wo-working); state="$dir/state"; out="$dir/watch.out"
  make_task "$state" worker1 ship "$(stamped paused 100 'old wait')
$(stamped working 5 'back at it')"
  printf '1 2 3\n' > "$state/.wait-over-worker1"
  result=$(run_watcher "$dir")
  [ "$result" = quiet ] || fail "a working line after the wait still woke: $(cat "$out")"
  [ ! -e "$state/.wait-over-worker1" ] || fail "a finished wait kept its marker"
  pass "a newer status line starts a new wait or ends it, and the old one never wakes"
}

test_newer_turn_starts_a_new_wait_after_the_alarm() {
  local dir state out result
  dir=$(make_case wo-newturn); state="$dir/state"; out="$dir/watch.out"
  make_task "$state" worker1 ship "$(stamped paused 120 'still waiting')"
  age_marker "$state" worker1 turn-ended 10
  result=$(run_watcher "$dir")
  [ "$result" = quiet ] || fail "a turn ended 10 minutes ago still counted the old wait: $(cat "$out")"
  age_marker "$state" worker1 turn-ended 100
  result=$(run_watcher "$dir")
  [ "$result" = woke ] || fail "a wait measured from a 100-minute-old turn raised no wake"
  : > "$out"
  result=$(run_watcher "$dir")
  [ "$result" = quiet ] || fail "the same wait woke again after the alarm: $(cat "$out")"
  age_marker "$state" worker1 turn-ended 50
  result=$(run_watcher "$dir")
  [ "$result" = woke ] || fail "a newer turn followed by 45 more minutes raised no new wake"
  grep -E '^check: wait-over worker1 5[01]m: paused: still waiting$' "$out" >/dev/null \
    || fail "the second wake reads wrong: $(cat "$out")"
  pass "a newer completed turn starts a new wait that wakes again after its own 45 minutes"
}

# The marker measurement for progress is pending (W4): progress is left out of the
# start time, so a worker that is parked in a shell wait cannot hide its alarm.
test_progress_does_not_postpone_the_alarm() {
  local dir state out result
  dir=$(make_case wo-progress); state="$dir/state"; out="$dir/watch.out"
  make_task "$state" worker1 ship "$(stamped paused 100 'sleeping in a shell')"
  age_marker "$state" worker1 progress 1
  result=$(run_watcher "$dir")
  [ "$result" = woke ] || fail "a fresh progress marker hid the alarm"
  pass "a fresh progress marker does not postpone the alarm"
}

test_unstamped_line_uses_the_status_file_mtime() {
  local dir state out result
  dir=$(make_case wo-unstamped); state="$dir/state"; out="$dir/watch.out"
  printf 'paused: waiting for a person\n' > "$state/worker1.status"
  printf 'kind=ship\nbackend=tmux\n' > "$state/worker1.meta"
  set_mtime $(( $(date +%s) - 60 * MIN )) "$state/worker1.status"
  prime_seen "$state/worker1.status"
  result=$(run_watcher "$dir")
  [ "$result" = woke ] || fail "an unstamped paused line with an old file raised no wake"
  grep -E '^check: wait-over worker1 6[01]m: paused: waiting for a person$' "$out" >/dev/null \
    || fail "the unstamped wake reads wrong: $(cat "$out")"
  pass "a line with no [at=] stamp starts its wait at the status file's mtime"
}

test_note_is_trimmed_to_160_characters() {
  local dir state out result note
  dir=$(make_case wo-note); state="$dir/state"; out="$dir/watch.out"
  note=$(printf 'x%.0s' $(seq 1 300))
  make_task "$state" worker1 ship "$(stamped blocked 60 "$note")"
  result=$(run_watcher "$dir")
  [ "$result" = woke ] || fail "a long note raised no wake"
  grep -E "^check: wait-over worker1 [0-9]+m: blocked: x{160}\$" "$out" >/dev/null \
    || fail "the note was not trimmed to 160 characters: $(cat "$out")"
  pass "the wake note is trimmed to 160 characters"
}

test_config_values() {
  local dir state out result
  # absent -> 45 is the other cases. 30 -> 30.
  dir=$(make_case wo-cfg-30); state="$dir/state"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  printf '30\n' > "$dir/config/wait-over-minutes"
  make_task "$state" worker1 ship "$(stamped paused 31 'thirty-one minutes')"
  result=$(run_watcher "$dir" "FM_CONFIG_OVERRIDE=$dir/config")
  [ "$result" = woke ] || fail "config 30 did not wake at 31 minutes"
  grep -E '^check: wait-over worker1 3[12]m: paused:' "$out" >/dev/null || fail "config 30 wake reads wrong: $(cat "$out")"
  dir=$(make_case wo-cfg-30-under); state="$dir/state"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  printf '30\n' > "$dir/config/wait-over-minutes"
  make_task "$state" worker1 ship "$(stamped paused 20 'twenty minutes')"
  result=$(run_watcher "$dir" "FM_CONFIG_OVERRIDE=$dir/config")
  [ "$result" = quiet ] || fail "config 30 woke at 20 minutes: $(cat "$out")"
  # off -> never.
  dir=$(make_case wo-cfg-off); state="$dir/state"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  printf 'off\n' > "$dir/config/wait-over-minutes"
  make_task "$state" worker1 ship "$(stamped paused 500 'a very long wait')"
  result=$(run_watcher "$dir" "FM_CONFIG_OVERRIDE=$dir/config")
  [ "$result" = quiet ] || fail "config off still woke: $(cat "$out")"
  pass "config/wait-over-minutes sets the limit, and off stops the alarm"
}

test_malformed_config_falls_back_and_wakes_once() {
  local dir state out result
  dir=$(make_case wo-cfg-bad); state="$dir/state"; out="$dir/watch.out"
  mkdir -p "$dir/config"
  printf 'abc\n' > "$dir/config/wait-over-minutes"
  make_task "$state" worker1 ship "$(stamped paused 50 'fifty minutes')"
  result=$(run_watcher "$dir" "FM_CONFIG_OVERRIDE=$dir/config")
  [ "$result" = woke ] || fail "a malformed config raised no wake"
  grep -Fx 'check: config/wait-over-minutes unreadable, using 45' "$out" >/dev/null \
    || fail "the malformed-config wake reads wrong: $(cat "$out")"
  : > "$out"
  result=$(run_watcher "$dir" "FM_CONFIG_OVERRIDE=$dir/config")
  [ "$result" = woke ] || fail "the 45 fallback did not fire the wait at 50 minutes"
  grep -E '^check: wait-over worker1 5[01]m: paused: fifty minutes$' "$out" >/dev/null \
    || fail "the fallback wake reads wrong: $(cat "$out")"
  grep -F 'config/wait-over-minutes' "$out" >/dev/null && fail "the config wake repeated: $(cat "$out")"
  : > "$out"
  result=$(run_watcher "$dir" "FM_CONFIG_OVERRIDE=$dir/config")
  [ "$result" = quiet ] || fail "a third run woke again: $(cat "$out")"
  pass "a malformed limit falls back to 45 and wakes about the file once"
}

test_fires_once_for_one_wait
test_under_the_limit_is_quiet
test_each_wait_verb_fires
test_other_verbs_and_kinds_raise_nothing
test_newer_status_line_starts_a_new_wait
test_newer_turn_starts_a_new_wait_after_the_alarm
test_progress_does_not_postpone_the_alarm
test_unstamped_line_uses_the_status_file_mtime
test_note_is_trimmed_to_160_characters
test_config_values
test_malformed_config_falls_back_and_wakes_once
