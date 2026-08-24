#!/usr/bin/env bash
# tests/fm-stale-work-evidence.test.sh - the work-evidence extension on the
# wedge path: crew_work_evidence (bin/fm-classify-lib.sh) and the bounded
# deferral wedge_timer_check spends on it (bin/fm-watch.sh).
#
# The defect this pins: a fixed FM_STALE_ESCALATE_SECS timer escalated work that
# was demonstrably running, because a gate measured at 311s outlasts the 240s
# default. Evidence now restarts that timer, but only up to
# FM_WORK_EVIDENCE_MAX_SECS per stale episode, so a hung worker is still caught.
#
# Both evidence sources are kernel facts, so this suite drives them with REAL
# processes and REAL file mtimes and needs no harness, no tmux, and no vendor
# binary. The two sources are deliberately driven apart: every positive case
# also asserts what the verdict becomes when that ONE source is taken away, so a
# case cannot pass vacuously on the other source (or on a probe that silently
# stopped answering at all). Tests call the real functions and assert their
# verdicts, wake queue, and timer files - never the probe's own source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-stale-work-evidence)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

WORKERS=()
cleanup() {
  local p
  for p in "${WORKERS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

# Pinned so the assertions do not depend on this host's defaults. Exported
# before sourcing because the watcher and the classifier resolve them once, at
# source time.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_STALE_ESCALATE_SECS=240
export FM_WORK_EVIDENCE_FILE_SECS=240
export FM_WORK_EVIDENCE_MAX_SECS=3600

# The watcher's source guard loads its functions without taking the singleton
# lock or entering the blocking loop.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

WAKE_LOG="$TMP/wakes"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }

# A live process whose working directory IS <dir>, published in WORKER_PID.
# exec replaces the subshell so the surviving process, not a shell wrapper, is
# the one the kernel records; the pid is returned through a global rather than
# stdout because a command substitution would wait on the background job's own
# inherited stdout.
WORKER_PID=
start_worker_in() {  # <dir>
  local dir=$1 i=0
  ( cd "$dir" && exec sleep 300 ) >/dev/null 2>&1 &
  WORKER_PID=$!
  WORKERS+=("$WORKER_PID")
  # Do not race the probe against fork/exec: wait until the kernel actually
  # reports the new cwd, so a negative result later is a real absence.
  while [ "$i" -lt 100 ]; do
    [ "$(readlink "/proc/$WORKER_PID/cwd" 2>/dev/null)" = "$dir" ] && return 0
    i=$((i + 1))
    sleep 0.05
  done
  fail "the test worker never reported a working directory of $dir"
}

stop_worker() {  # <pid>
  local pid=$1 i=0
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  while [ "$i" -lt 100 ] && [ -e "/proc/$pid/cwd" ]; do
    i=$((i + 1))
    sleep 0.05
  done
}

# A git worktree whose only change is one untracked file, so the changed-file
# signal has exactly one thing to find and the test controls its mtime.
make_changed_repo() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.email fm@test
  git -C "$dir" config user.name fm
  printf 'seed\n' > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm seed
  printf 'in progress\n' > "$dir/changed.txt"
}

if [ ! -d /proc/1 ]; then
  printf 'skip: no procfs, the live-process evidence source cannot be exercised here\n'
  exit 0
fi

# --- the probe: each source proves itself, and proves the other was absent ----

test_live_process_alone_is_evidence() {
  local dir="$TMP/proc-only" pid verdict after
  mkdir -p "$dir"
  start_worker_in "$dir"
  pid=$WORKER_PID
  verdict=$(crew_work_evidence "$dir" 240)
  [ "$verdict" = process ] \
    || fail "a live process rooted in the worktree must be work evidence, got '$verdict'"

  # Take that one source away. This directory is not a repository, so the
  # changed-file source has nothing to say about it at all: the SAME directory
  # must flip straight to no-evidence, which proves the `process` above came
  # from the live process and not from a file signal quietly agreeing in the
  # background.
  stop_worker "$pid"
  after=$(crew_work_evidence "$dir" 240)
  [ "$after" = none ] \
    || fail "with the process gone and no repository to read, there is no evidence left, got '$after'"
  pass "a live process rooted in the worktree is work evidence on its own"
}

test_recent_change_alone_is_evidence() {
  local dir="$TMP/files-only" verdict after
  make_changed_repo "$dir"
  verdict=$(crew_work_evidence "$dir" 240)
  [ "$verdict" = files ] \
    || fail "a just-changed file in the worktree must be work evidence, got '$verdict'"

  # No process was ever started here, so this verdict came from file mtimes
  # alone. Age that one file and the SAME directory must report a definite
  # `none` - both sources answered, neither found work - rather than `unknown`.
  touch -t 202001010000 "$dir/changed.txt"
  after=$(crew_work_evidence "$dir" 240)
  [ "$after" = none ] \
    || fail "an aged change with no process must be a definite no-evidence answer, got '$after'"
  pass "a recently changed file is work evidence on its own, and goes stale on its own"
}

test_symlinked_worktree_still_sees_its_process() {
  local real="$TMP/real-wt" link="$TMP/linked-wt" pid verdict
  mkdir -p "$real"
  ln -s "$real" "$link"
  start_worker_in "$real"
  pid=$WORKER_PID
  # A recorded worktree can carry a symlinked prefix while the kernel reports the
  # physical path. The same running worker must be found through either spelling.
  verdict=$(crew_work_evidence "$link" 240)
  [ "$verdict" = process ] \
    || fail "a worker must be found through a symlinked worktree path, got '$verdict'"
  stop_worker "$pid"
  pass "a symlinked worktree path finds the same live process the kernel reports"
}

test_unanswerable_probe_reports_unknown() {
  local verdict
  verdict=$(crew_work_evidence "$TMP/does-not-exist" 240)
  [ "$verdict" = unknown ] \
    || fail "an unreadable worktree must be unanswerable, got '$verdict'"
  verdict=$(crew_work_evidence "" 240)
  [ "$verdict" = unknown ] \
    || fail "an unrecorded worktree must be unanswerable, got '$verdict'"
  pass "a probe that cannot answer says so instead of reporting no evidence"
}

# --- the watcher: what one bounded extension buys, and where it stops ---------

WINDOW=default:w1:p1
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
SINCE="$STATE_DIR/.stale-since-$KEY"
ESCALATIONS="$STATE_DIR/.wedge-escalations-$KEY"
ANCHOR="$STATE_DIR/.work-evidence-$KEY"
EPISODE=hash-a

# Arm a stale episode that is already past FM_STALE_ESCALATE_SECS, so the very
# next wedge_timer_check either escalates or defers.
arm_overdue_stale() {  # <worktree-or-empty>
  local wt=$1
  rm -f "$STATE_DIR"/*.meta "$SINCE" "$ESCALATIONS" "$ANCHOR" \
    "$STATE_DIR/.wake-queue" "$STATE_DIR/.wake-queue.seq"
  : > "$WAKE_LOG"
  if [ -n "$wt" ]; then
    fm_write_meta "$STATE_DIR/wk.meta" "window=$WINDOW" "kind=ship" "worktree=$wt"
  else
    fm_write_meta "$STATE_DIR/wk.meta" "window=$WINDOW" "kind=ship"
  fi
  printf '%s' "$EPISODE" > "$STATE_DIR/.stale-$KEY"
  echo $(( $(date +%s) - 500 )) > "$SINCE"
}

assert_escalated() {  # <label>
  local label=$1
  grep -q 'possible wedge' "$WAKE_LOG" \
    || fail "$label: expected a possible-wedge escalation, wakes: $(cat "$WAKE_LOG")"
  grep -q "stale" "$STATE_DIR/.wake-queue" 2>/dev/null \
    || fail "$label: the escalation must be durably queued"
}

assert_not_escalated() {  # <label>
  local label=$1
  [ ! -s "$WAKE_LOG" ] \
    || fail "$label: expected no escalation, got: $(cat "$WAKE_LOG")"
  [ ! -e "$STATE_DIR/.wake-queue" ] \
    || fail "$label: expected nothing queued, got: $(cat "$STATE_DIR/.wake-queue")"
}

test_long_gate_is_not_escalated() {
  local dir="$TMP/gate" pid restarted
  mkdir -p "$dir"
  start_worker_in "$dir"
  pid=$WORKER_PID
  arm_overdue_stale "$dir"
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_not_escalated "a worker with a live process in its worktree"
  restarted=$(cat "$SINCE")
  [ $(( $(date +%s) - restarted )) -lt 10 ] \
    || fail "the escalation clock must restart on evidence, since=$restarted"
  [ -s "$ANCHOR" ] || fail "the bounded extension must record when it started"
  [ ! -e "$ESCALATIONS" ] || fail "a deferred episode must not count an escalation"
  stop_worker "$pid"
  pass "a worker running a long gate is not escalated as a possible wedge"
}

test_no_evidence_still_escalates() {
  local dir="$TMP/quiet"
  make_changed_repo "$dir"
  touch -t 202001010000 "$dir/changed.txt"
  arm_overdue_stale "$dir"
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_escalated "no process and no recent change"
  [ "$(cat "$ESCALATIONS")" = 1 ] || fail "the escalation count must still be kept"
  [ ! -e "$SINCE" ] || fail "an escalation must still clear its timer"
  pass "a stale pane with no process and no recent change escalates as it does today"
}

test_unanswerable_probe_leaves_behavior_unchanged() {
  arm_overdue_stale ""
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_escalated "no worktree recorded"
  [ ! -e "$ANCHOR" ] || fail "an unanswerable probe must not open an extension window"

  # Same task, a recorded worktree that no longer exists: still unanswerable,
  # still escalates.
  arm_overdue_stale "$TMP/vanished"
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_escalated "recorded worktree is gone"
  [ ! -e "$ANCHOR" ] || fail "a missing worktree must not open an extension window"
  pass "a probe that cannot answer leaves the escalation exactly as it is today"
}

test_outer_bound_catches_a_hung_worker() {
  local dir="$TMP/hung" pid n1 n2
  mkdir -p "$dir"
  # A process that never exits is indistinguishable from real work by liveness
  # alone, which is precisely why the extension is bounded.
  start_worker_in "$dir"
  pid=$WORKER_PID
  arm_overdue_stale "$dir"

  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_not_escalated "a hung worker inside its extension window"

  # Age the extension past FM_WORK_EVIDENCE_MAX_SECS. The process is still
  # there and still reports as evidence - the bound, not the evidence, is what
  # must decide now.
  [ "$(crew_work_evidence "$dir" 240)" = process ] \
    || fail "the hung worker must still look like evidence, or this case proves nothing"
  printf '%s %s\n' "$EPISODE" "$(( $(date +%s) - (FM_WORK_EVIDENCE_MAX_SECS + 60) ))" > "$ANCHOR"
  echo $(( $(date +%s) - 500 )) > "$SINCE"
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_escalated "a hung worker past its extension window"
  n1=$(cat "$ESCALATIONS")
  [ "$n1" = 1 ] || fail "the first escalation past the bound must count as 1, got '$n1'"

  # And it keeps escalating on the ordinary cadence, so the repeat-escalation
  # count that drives demand-deep-inspection still accumulates.
  echo $(( $(date +%s) - 500 )) > "$SINCE"
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  n2=$(cat "$ESCALATIONS")
  [ "$n2" = 2 ] || fail "escalations past the bound must keep counting, got '$n2'"
  stop_worker "$pid"
  pass "a hung worker still escalates once its bounded extension is spent"
}

test_spent_window_is_bound_to_its_episode() {
  local dir="$TMP/next-episode" pid
  mkdir -p "$dir"
  start_worker_in "$dir"
  pid=$WORKER_PID
  arm_overdue_stale "$dir"
  # A spent extension left behind by a DIFFERENT stale episode must not disable
  # the extension for this one.
  printf 'hash-older %s\n' "$(( $(date +%s) - (FM_WORK_EVIDENCE_MAX_SECS + 60) ))" > "$ANCHOR"
  wedge_timer_check "$WINDOW" "$SINCE" "non-terminal stale" "$ESCALATIONS"
  assert_not_escalated "a new stale episode after an older spent extension"
  [ "$(cut -d' ' -f1 < "$ANCHOR")" = "$EPISODE" ] \
    || fail "the extension window must be re-anchored on the current episode"
  stop_worker "$pid"
  pass "a spent extension window belongs to its own stale episode, not the window forever"
}

test_live_process_alone_is_evidence
test_recent_change_alone_is_evidence
test_symlinked_worktree_still_sees_its_process
test_unanswerable_probe_reports_unknown
test_long_gate_is_not_escalated
test_no_evidence_still_escalates
test_unanswerable_probe_leaves_behavior_unchanged
test_outer_bound_catches_a_hung_worker
test_spent_window_is_bound_to_its_episode
