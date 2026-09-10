#!/usr/bin/env bash
# tests/fm-watch-paused-live-crew.test.sh - what a LIVE ordinary crew that
# declared "paused:" costs its supervisor, in bin/fm-watch.sh.
#
# The defect this pins: pause_state_class ran its dead-agent gate on every poll
# of a non-self-supervising crew, so an authoritative paused verdict from
# crew_absorb_class was replaced with "none" for as long as the agent stayed
# alive. Every idle-pane content change then re-entered the first-sight branch
# and woke firstmate with a bare "stale: <window>" - no annotation, so the wake
# reads like a crew gone quiet rather than a declared wait. Observed live as four
# wakes in twenty minutes against a crew that was standing by exactly as its
# instructions told it to.
#
# The contract, at both levels:
#   - exactly ONE wake per pause episode, at its onset, carrying the "(paused
#     Ns, awaiting external ...)" annotation so firstmate learns the crew paused;
#   - ZERO bare "stale: <window>" wakes, however much the idle pane churns;
#   - nothing further until PAUSE_RESURFACE_SECS or a status change, which
#     tests/fm-watch-triage.test.sh already pins.
#
# The behavioral case drives a real fm-watch.sh subprocess across repeated
# content changes and counts the durable queue, because the queue is what costs
# firstmate a turn. The unit cases pin the verdict pause_state_class itself
# returns, driving its two inputs - the classifier verdict and backend liveness -
# apart deliberately, so no case can pass on the other input or on the status
# line alone.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-paused-live-crew)

# Local process helpers, matching tests/fm-watch-triage.test.sh: a watcher that
# is still running after <limit> ticks absorbed its poll, one that exited
# surfaced a wake.
wait_live() {  # <pid> [limit]
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

expect_class() {  # <expected> <actual> <label>
  [ "$2" = "$1" ] || fail "$3: expected '$1', got '$2'"
}

# --- behavioral: what the fleet's supervisor actually pays ------------------

# A live crew, idle at a declared pause, whose pane content changes on every
# poll - the churn a rendering agent produces on its own (a ticking elapsed-time
# line, a cursor) with no work happening at all.
test_churning_idle_pause_costs_exactly_one_annotated_wake() {
  local dir state fakebin out capture_file window key statusf pid round wakes bare annotated
  local drained err surfaces=0
  dir=$(make_case churning-idle-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  drained="$dir/drained.log"; err="$dir/drain.err"; : > "$drained"
  window="test:fm-standby"
  statusf="$state/standby.status"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/standby.meta"
  printf 'paused: ready, standing by for the captain\n' > "$statusf"
  prime_status_seen "$state" "$statusf"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  round=1
  while [ "$round" -le 5 ]; do
    # New pane content every round: this is the trigger, and it must not decide
    # anything. FM_FAKE_TMUX_CURRENT_COMMAND names a real agent, so the backend
    # reports the agent ALIVE - the case the pause cadence exists to serve.
    printf 'standing by (elapsed %sm)\n' "$round" > "$capture_file"
    printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=claude \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · ready, standing by for the captain' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    # A watcher still running absorbed its poll; one that exited surfaced a
    # wake, which is the turn end it costs firstmate.
    # A watcher still running absorbed its poll. One that exited surfaced
    # something; drain and acknowledge it so the next round starts clean and
    # every wake is counted once, exactly as firstmate's supervision cycle would.
    # Restarting a watcher this way also produces the unrelated
    # "check: rearm-resurface" downtime wake, so the assertions below count what
    # this crew cost firstmate - stale wakes - rather than every exit.
    if wait_live "$pid" 15; then
      reap "$pid"
    else
      wait "$pid" || true
      FM_STATE_OVERRIDE="$state" "$DRAIN" >> "$drained" 2> "$err" \
        || fail "drain after a paused surface failed"
      ack_drain_err "$state" "$err" >/dev/null || fail "could not acknowledge a paused surface"
    fi
    round=$((round + 1))
  done

  surfaces=$(grep -c "^stale: $window" "$out" 2>/dev/null || true)
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$drained")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$drained")
  annotated=$(grep -c "awaiting external" "$drained" 2>/dev/null || true)
  [ "$surfaces" -eq 1 ] || fail "a live declared pause surfaced $surfaces stale wakes across five content changes, expected exactly 1"
  [ "$bare" -eq 0 ] || fail "a live declared pause produced $bare bare stale wakes across five content changes"
  [ "$wakes" -eq 1 ] || fail "a live declared pause produced $wakes stale wakes across five content changes, expected exactly 1"
  [ "$annotated" -eq 1 ] || fail "the one pause wake was not the annotated declared-wait wake"
  [ -e "$state/.paused-$key" ] || fail "the pause episode was not recorded, so later polls would re-open it"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared pause must not run the wedge timer"
  pass "a churning idle pause costs exactly one annotated wake and never a bare stale wake"
}

# --- unit: the verdict pause_state_class returns ---------------------------

# Sourced in a subshell per case so the watcher's source-time STATE binding and
# the stubs below cannot leak into the behavioral case above.
run_class() {  # <fake-class> <fake-alive> <episode-open: yes|no>
  local fake_class=$1 fake_alive=$2 episode=$3
  (
    # fake_* names deliberately avoid pause_state_class's own locals, which
    # would shadow them inside the stubs.
    dir=$(make_case "unit-$fake_class-$fake_alive-$episode")
    state="$dir/state"
    export FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_STALE_ESCALATE_SECS=240
    win=test:fm-standby
    task=standby
    printf 'window=%s\nkind=ship\nbackend=tmux\n' "$win" > "$state/$task.meta"
    printf 'working: under way\npaused: ready, standing by for the captain\n' > "$state/$task.status"
    # The watcher's source guard loads its functions without taking the
    # singleton lock or entering the blocking loop.
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    # The two inputs the verdict combines. The real ones need a worktree, a
    # harness and a live pane; their verdicts are what this function must honour.
    # shellcheck disable=SC2329  # called indirectly, from pause_state_class
    crew_absorb_class() { printf '%s' "$fake_class"; }
    # shellcheck disable=SC2329  # called indirectly, from pause_state_class
    fm_backend_agent_alive() { printf '%s' "$fake_alive"; }
    if [ "$episode" = yes ]; then
      : > "$state/.paused-${win//:/_}"
      date +%s > "$state/.paused-rechecked-${win//:/_}"
    fi
    pause_state_class "$win" "$task"
  )
}

test_established_pause_is_honoured_while_the_agent_lives() {
  expect_class paused "$(run_class paused alive yes)" \
    "an open pause episode on a live crew must classify paused"
  pass "an open pause episode is honoured for a live crew instead of re-surfaced as stale"
}

test_pause_onset_still_surfaces_once() {
  expect_class none "$(run_class paused alive no)" \
    "the onset of a pause on a live crew must still surface once"
  pass "the onset of a live crew's pause still surfaces once, annotated"
}

test_live_crew_without_a_classifier_pause_never_invents_one() {
  expect_class none "$(run_class none alive no)" \
    "a live crew with no classifier pause must still surface"
  pass "no pause is invented for a live crew the classifier does not call paused"
}

test_dead_crew_still_recovers_a_fallen_back_pause() {
  # Same classifier verdict and same closed episode as the case above - only
  # liveness differs, so neither case can pass on the status line.
  expect_class paused "$(run_class none dead no)" \
    "a confidently dead crew must still recover paused"
  pass "the dead-agent rescue the gate exists for is preserved"
}

test_working_crew_outranks_its_own_stale_pause() {
  expect_class working "$(run_class working alive no)" \
    "a provably working crew must outrank a stale paused: line"
  pass "a provably working crew still outranks its own stale pause declaration"
}

test_churning_idle_pause_costs_exactly_one_annotated_wake
test_established_pause_is_honoured_while_the_agent_lives
test_pause_onset_still_surfaces_once
test_live_crew_without_a_classifier_pause_never_invents_one
test_dead_crew_still_recovers_a_fallen_back_pause
test_working_crew_outranks_its_own_stale_pause
