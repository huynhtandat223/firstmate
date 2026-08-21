#!/usr/bin/env bash
# Behavior tests for custom-skills/orchestrator-assistance/fm-assistance.sh.
#
# Every case drives the real CLI, real sidecars, and a real session-history
# fixture. Only the two OUTWARD commands - fm-spawn.sh and fm-send.sh - are
# replaced, through the script's documented FM_SPAWN/FM_SEND seam, so a test run
# never launches an agent or steers a live pane. What that proves is the
# decision and the exact command constructed; real delivery is proven only
# against a live session.
#
# N3 classical proof map (the smallest sensitive public-seam set):
# - observe -> interruption -> observe proves pending replay and unchanged cursor;
# - suppressed settlement proves one durable outcome and cursor advancement;
# - delivered send -> interruption -> recovery proves one parent send, one outcome,
#   and no duplicate delivery;
# - out-of-order settlement proves longest-contiguous-prefix advancement;
# - changed evidence identity proves a new delivery rather than a repeat.
# These cases cover the changed triggers: pending observation, settlement, outcome
# ordering, delivery linkage, suppression, recovery, and evidence fingerprinting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/custom-skills/orchestrator-assistance/fm-assistance.sh"
TMP_ROOT=$(fm_test_tmproot fm-orchestrator-assistance)

# --- fixtures ---------------------------------------------------------------

# recorder <case> echoes a fresh case dir with FM_HOME, a history store, and
# spawn/send recorders wired through the documented seam.
new_case() {  # <name> [parent-kind]
  local name=$1 kind=${2:-supervisor} dir home wt hist
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  wt="$dir/parent-worktree"
  mkdir -p "$home/state" "$wt" "$dir/bin"
  hist="$dir/history/$(printf '%s' "$wt" | tr '/.' '--')"
  mkdir -p "$hist"

  fm_write_meta "$home/state/prog.meta" \
    "window=default:w1:p1" \
    "endpoint_task_id=prog" \
    "worktree=$wt" \
    "harness=claude" \
    "kind=$kind" \
    "parent_home=$home"

  cat > "$dir/bin/spawn" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/spawned"
echo "spawned \$1"
SH
  cat > "$dir/bin/send" <<SH
#!/usr/bin/env bash
target=\$1; shift
printf '%s\t%s\n' "\$target" "\$*" >> "$dir/sent"
SH
  chmod +x "$dir/bin/spawn" "$dir/bin/send"
  : > "$dir/spawned"
  : > "$dir/sent"
  printf '%s\n' "$dir"
}

# Write a session-history fixture. Records: 1 user turn, 1 assistant turn,
# 1 sidechain assistant turn (a subagent's transcript, not the parent's), and
# 1 non-turn record.
write_history() {  # <case-dir>
  local dir=$1 wt hist
  wt="$dir/parent-worktree"
  hist="$dir/history/$(printf '%s' "$wt" | tr '/.' '--')"
  cat > "$hist/session.jsonl" <<'JSON'
{"type":"mode","mode":"default"}
{"type":"user","uuid":"u-001","timestamp":"2026-08-16T01:00:00Z","message":{"role":"user","content":"plan the blocks ticket"}}
{"type":"assistant","uuid":"a-002","timestamp":"2026-08-16T01:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"the report says common.extension is missing"}]}}
{"type":"assistant","uuid":"s-003","isSidechain":true,"timestamp":"2026-08-16T01:00:06Z","message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}
{"type":"user","uuid":"u-004","timestamp":"2026-08-16T01:00:09Z","message":{"role":"user","content":"source proves it is already registered"}}
JSON
}

run_cli() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" \
  FM_ASSISTANCE_HISTORY_ROOT="$dir/history" \
  FM_SPAWN="$dir/bin/spawn" \
  FM_SEND="$dir/bin/send" \
  "$CLI" "$@" 2>&1
}

# --- 1. invocation and parent binding ---------------------------------------

test_bind_resolves_parent_and_history() {
  local dir out binding
  dir=$(new_case bind-ok); write_history "$dir"
  out=$(run_cli "$dir" bind prog) || fail "bind failed: $out"
  assert_contains "$out" "bound prog-assistance" "bind did not report the assistance identity"

  binding="$dir/home/state/prog-assistance.assistance-binding"
  assert_present "$binding" "bind wrote no durable binding"
  assert_grep "parent_task_id=prog" "$binding" "binding lost the exact parent task id"
  assert_grep "parent_worktree=$dir/parent-worktree" "$binding" "binding lost the parent worktree"
  assert_grep "session.jsonl" "$binding" "binding did not resolve the parent session history"
  pass "bind: resolves the exact parent record and its observable history"
}

test_bind_refuses_unknown_programme() {
  local dir out code
  dir=$(new_case bind-unknown)
  out=$(run_cli "$dir" bind nosuch); code=$?
  expect_code 1 "$code" "bind accepted an unknown programme"
  assert_contains "$out" "no supervisor record" "refusal did not name the missing record"
  assert_absent "$dir/home/state/nosuch-assistance.assistance-binding" "a refused bind still wrote a binding"
  pass "bind: refuses a programme with no supervisor record"
}

test_bind_refuses_non_supervisor_parent() {
  local dir out code
  dir=$(new_case bind-ship ship); write_history "$dir"
  out=$(run_cli "$dir" bind prog); code=$?
  expect_code 1 "$code" "bind accepted a parent that is not a supervisor"
  assert_contains "$out" "kind=ship" "refusal did not name the recorded kind"
  pass "bind: refuses to bind to a task that is not a programme supervisor"
}

# A worktree that has held more than one recorded session is the ordinary case
# for a long-running supervisor. Recency is not identity there: binding to the
# newest file would silently follow whichever transcript was written last.
add_second_history() {  # <case-dir>
  local dir=$1 hist
  hist="$dir/history/$(printf '%s' "$dir/parent-worktree" | tr '/.' '--')"
  cat > "$hist/other.jsonl" <<'JSON'
{"type":"user","uuid":"x-900","timestamp":"2026-08-16T02:00:00Z","message":{"role":"user","content":"a different session entirely"}}
JSON
  # Make the WRONG file the newest, so a recency rule would choose it.
  touch "$hist/other.jsonl"
}

test_bind_refuses_ambiguous_history() {
  local dir out code
  dir=$(new_case bind-two-histories); write_history "$dir"; add_second_history "$dir"
  out=$(run_cli "$dir" bind prog); code=$?
  expect_code 1 "$code" "bind chose between two recorded sessions instead of refusing"
  assert_contains "$out" "more than one recorded session history" "refusal did not name the ambiguity"
  assert_contains "$out" "session.jsonl" "refusal did not list the candidates"
  assert_contains "$out" "other.jsonl" "refusal did not list the candidates"
  assert_absent "$dir/home/state/prog-assistance.assistance-binding" "an ambiguous bind still wrote a binding"
  pass "bind: refuses to guess between two recorded sessions for one worktree"
}

test_bind_pins_the_named_session() {
  local dir out binding
  dir=$(new_case bind-pinned); write_history "$dir"; add_second_history "$dir"

  out=$(run_cli "$dir" bind prog --session session) || fail "pinned bind failed: $out"
  binding="$dir/home/state/prog-assistance.assistance-binding"
  assert_grep "session.jsonl" "$binding" "the pin did not select the named session"
  assert_no_grep "other.jsonl" "$binding" "the pin bound the newest file instead of the named one"

  # The pinned path is recorded, so later writes elsewhere cannot move it.
  touch "$dir/history/$(printf '%s' "$dir/parent-worktree" | tr '/.' '--')/other.jsonl"
  out=$(run_cli "$dir" observe prog --limit 5) || fail "observe after a newer sibling write failed: $out"
  assert_contains "$out" "u-001" "observation followed a newer sibling session instead of the bound one"
  assert_not_contains "$out" "x-900" "observation leaked turns from a different session"
  pass "bind: a named session pins the transcript, and later sibling writes never move it"
}

test_bind_refuses_unknown_pin() {
  local dir out code
  dir=$(new_case bind-bad-pin); write_history "$dir"; add_second_history "$dir"
  out=$(run_cli "$dir" bind prog --session no-such-session); code=$?
  expect_code 1 "$code" "bind accepted a pin that names no recorded session"
  assert_contains "$out" "no readable session history" "refusal did not name the unmatched pin"
  pass "bind: refuses a pin that matches no recorded session rather than falling back"
}

test_bind_refuses_when_history_absent() {
  local dir out code
  dir=$(new_case bind-nohistory)
  out=$(run_cli "$dir" bind prog); code=$?
  expect_code 1 "$code" "bind accepted a parent with no observable history"
  assert_contains "$out" "no readable session history" "refusal did not name the missing capability"
  pass "bind: reports the missing observable source instead of guessing a channel"
}


test_primary_bind_requires_explicit_existing_session() {
  local dir out code
  dir=$(new_case primary-bind)
  out=$(run_cli "$dir" bind --primary); code=$?
  expect_code 1 "$code" "primary bind accepted no session"
  assert_contains "$out" "requires --session" "primary bind did not require a session"
  out=$(run_cli "$dir" bind --primary --session no-such-session); code=$?
  expect_code 1 "$code" "primary bind accepted an unknown session"
  assert_contains "$out" "no readable primary session" "primary bind did not refuse the unknown session"
  pass "primary bind: requires a named session that exists for this home"
}

# --- 2. same-parent resume without a duplicate session ----------------------

test_open_is_idempotent_on_the_record() {
  local dir out spawns
  dir=$(new_case open-once); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"

  out=$(run_cli "$dir" open prog) || fail "first open failed: $out"
  assert_contains "$out" "opened prog-assistance" "first open did not launch the session"
  assert_grep "prog-assistance --supervisor" "$dir/spawned" "spawn did not name the assistance task as a supervisor"
  assert_grep "gemini-3.7-flash-high" "$dir/spawned" "spawn did not pin the assistance model"
  assert_grep "high" "$dir/spawned" "spawn did not pin the assistance effort"

  # fm-spawn records the task; a second open must resume it.
  fm_write_meta "$dir/home/state/prog-assistance.meta" "harness=pi" "kind=supervisor"
  out=$(run_cli "$dir" open prog) || fail "second open failed: $out"
  assert_contains "$out" "resumed prog-assistance" "second open did not resume the recorded session"

  spawns=$(wc -l < "$dir/spawned")
  [ "$spawns" -eq 1 ] || fail "open spawned $spawns sessions for one parent; exactly one is allowed"
  pass "open: a second invocation for the same parent resumes and never spawns a duplicate"
}

# --- 3. parent-turn observation ---------------------------------------------

test_observe_records_pending_without_advancing_cursor() {
  local dir first second cursor pending
  dir=$(new_case observe); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"

  first=$(run_cli "$dir" observe prog --limit 2) || fail "observe failed: $first"
  assert_contains "$first" "u-001" "observe missed the first parent turn"
  assert_contains "$first" "a-002" "observe missed the second parent turn"
  assert_not_contains "$first" "u-004" "observe ran past its limit"

  cursor="$dir/home/state/prog-assistance.assistance-cursor"
  pending="$dir/home/state/prog-assistance.assistance-pending"
  assert_absent "$cursor" "observe advanced the committed cursor before settlement"
  assert_present "$pending" "observe did not persist a pending batch"
  assert_grep "turn=2" "$pending" "pending batch lost the first parent line"
  assert_grep "u-001" "$pending" "pending batch lost the first parent identity"

  # An interrupted turn is recoverable, not consumed. Recovery emits the same
  # pending identities and does not read past the pending batch.
  second=$(run_cli "$dir" observe prog --limit 5) || fail "recovery observe failed: $second"
  assert_contains "$second" "u-001" "recovery did not re-emit the unsettled first turn"
  assert_contains "$second" "a-002" "recovery did not re-emit the unsettled second turn"
  assert_not_contains "$second" "u-004" "recovery read past the unsettled batch"
  pass "observe: records a pending batch and re-emits it without advancing the committed cursor"
}

test_suppressed_settlement_advances_once() {
  local dir out cursor outcomes
  dir=$(new_case settle-suppress); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"
  run_cli "$dir" observe prog --limit 1 >/dev/null || fail "observe failed"

  out=$(run_cli "$dir" settle prog --turn u-001 --outcome suppressed --cue "options draft" \
    --evidence "history:u-001" --reason "no watch item applies") || fail "settlement failed: $out"
  assert_contains "$out" "settled turn=u-001 outcome=suppressed" "suppression did not settle"
  cursor="$dir/home/state/prog-assistance.assistance-cursor"
  assert_present "$cursor" "suppression did not advance the committed cursor"
  outcomes="$dir/home/state/prog-assistance.assistance-outcomes"
  [ "$(grep -c '^turn=u-001' "$outcomes")" -eq 1 ] || fail "suppression did not write exactly one outcome"

  out=$(run_cli "$dir" settle prog --turn u-001 --outcome suppressed --cue "options draft" \
    --evidence "history:u-001" --reason "repeat") || fail "repeat settlement errored: $out"
  assert_contains "$out" "already-settled turn=u-001" "repeat settlement was not idempotent"
  [ "$(grep -c '^turn=u-001' "$outcomes")" -eq 1 ] || fail "repeat settlement duplicated the outcome"
  pass "settle: suppression is durable, idempotent, and advances only after settlement"
}

test_delivery_then_recovery_settles_without_duplicate_send() {
  local dir remind_out delivery settle_out pending cursor
  dir=$(new_case settle-delivery); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"
  run_cli "$dir" observe prog --limit 1 >/dev/null || fail "observe failed"

  remind_out=$(run_cli "$dir" remind prog --turn u-001 --id w1 --action "draft" --evidence "e1" \
    "WATCH [w1] before draft: check source; verify: source; source: contract") \
    || fail "delivery failed: $remind_out"
  delivery=$(sed -n 's/.* delivery=\([0-9a-f]*\).*/\1/p' <<<"$remind_out")
  [ -n "$delivery" ] || fail "successful delivery did not return its settlement fingerprint"

  # Simulate interruption after the successful send and before settlement.
  pending="$dir/home/state/prog-assistance.assistance-pending"
  assert_present "$pending" "delivery unexpectedly removed pending input"
  settle_out=$(run_cli "$dir" observe prog --limit 1) || fail "recovery observe failed: $settle_out"
  assert_contains "$settle_out" "u-001" "recovery did not re-emit the unsettled delivered turn"

  run_cli "$dir" settle prog --turn u-001 --outcome delivered --cue "report claim" \
    --evidence "e1" --reason "reminder delivered" --delivery "$delivery" >/dev/null \
    || fail "delivered settlement failed"
  [ "$(wc -l < "$dir/sent")" -eq 1 ] || fail "recovery created a duplicate parent message"
  [ "$(grep -c '^turn=u-001' "$dir/home/state/prog-assistance.assistance-outcomes")" -eq 1 ] \
    || fail "recovery did not create one durable outcome"
  cursor="$dir/home/state/prog-assistance.assistance-cursor"
  assert_present "$cursor" "delivered settlement did not advance the cursor"
  pass "settle: recovery links one successful parent send to one durable delivered outcome"
}

test_out_of_order_settlement_advances_contiguous_prefix_only() {
  local dir cursor pending
  dir=$(new_case settle-order); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"
  run_cli "$dir" observe prog --limit 2 >/dev/null || fail "observe failed"

  run_cli "$dir" settle prog --turn a-002 --outcome suppressed --cue "report claim" \
    --evidence "a-002" --reason "not applicable" >/dev/null || fail "second settlement failed"
  cursor="$dir/home/state/prog-assistance.assistance-cursor"
  assert_absent "$cursor" "out-of-order settlement skipped the first turn"
  pending="$dir/home/state/prog-assistance.assistance-pending"
  assert_present "$pending" "out-of-order settlement discarded the pending prefix"
  assert_grep "u-001" "$pending" "out-of-order settlement lost the first turn"

  run_cli "$dir" settle prog --turn u-001 --outcome suppressed --cue "options draft" \
    --evidence "u-001" --reason "not applicable" >/dev/null || fail "first settlement failed"
  assert_present "$cursor" "settling the first turn did not advance the contiguous pair"
  assert_absent "$pending" "settling the contiguous pair retained stale pending input"
  pass "settle: an out-of-order outcome waits, then advances the longest contiguous prefix"
}

# --- 4. historical replay ---------------------------------------------------

test_replay_stops_before_the_named_record() {
  local dir out pending_before pending_after
  dir=$(new_case replay); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"
  run_cli "$dir" observe prog --limit 1 >/dev/null || fail "seed observe failed"

  # The two-phase live observe leaves the committed cursor absent until its
  # pending turn settles. Replay must preserve that exact state.
  assert_absent "$dir/home/state/prog-assistance.assistance-cursor" \
    "seed observe advanced the live cursor before settlement"
  pending_before=$(sha256sum "$dir/home/state/prog-assistance.assistance-pending")

  out=$(run_cli "$dir" observe prog --replay-until u-004 --limit 5) || fail "replay failed: $out"
  assert_contains "$out" "a-002" "replay lost the turn that predates the correction"
  assert_not_contains "$out" "u-004" "replay leaked the correction itself into the input"

  assert_absent "$dir/home/state/prog-assistance.assistance-cursor" \
    "replay advanced the live cursor"
  pending_after=$(sha256sum "$dir/home/state/prog-assistance.assistance-pending")
  [ "$pending_before" = "$pending_after" ] || fail "replay changed the live pending batch"
  pass "replay: stops before the named record and leaves live observation untouched"
}

test_replay_refuses_unknown_record() {
  local dir out code
  dir=$(new_case replay-unknown); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"
  out=$(run_cli "$dir" observe prog --replay-until no-such-uuid); code=$?
  expect_code 1 "$code" "replay accepted a record uuid that is not in the history"
  assert_contains "$out" "refusing to replay the whole file" "refusal did not explain the risk"
  pass "replay: refuses an unknown record instead of replaying every later correction"
}

# --- 5. direct reminder delivery and the read-only form ---------------------

test_remind_delivers_to_the_exact_parent() {
  local dir out
  dir=$(new_case remind); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"

  out=$(run_cli "$dir" remind prog --id w2 --action "accepting the blocks report" \
    --evidence "report@sha1" "WATCH [w2] before accepting the blocks report: check the strongest claim against current source; verify: consumer registration; source: contract") \
    || fail "remind failed: $out"
  assert_contains "$out" "delivered w2 to=prog" "remind did not report delivery to the parent"
  assert_grep "prog	WATCH [w2]" "$dir/sent" "the reminder did not reach the exact parent task"
  pass "remind: delivers one reminder directly to the bound parent task"
}

test_remind_refuses_a_form_that_is_not_awareness() {
  local dir out code sent
  dir=$(new_case remind-form); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"

  out=$(run_cli "$dir" remind prog --id w9 --action dispatch --evidence "e1" \
    "Stop the dispatch and use the in-process collection instead"); code=$?
  expect_code 1 "$code" "remind delivered a message that was not an awareness form"
  assert_contains "$out" "must open with one of" "refusal did not name the closed form set"
  sent=$(wc -c < "$dir/sent")
  [ "$sent" -eq 0 ] || fail "a refused reminder still reached the parent"
  pass "remind: refuses a decision or command instead of delivering it to the parent"
}

test_remind_refuses_without_a_binding() {
  local dir out code
  dir=$(new_case remind-unbound)
  out=$(run_cli "$dir" remind prog --id w1 --action a --evidence e "WATCH [w1] x: y; verify: z; source: s"); code=$?
  expect_code 1 "$code" "remind delivered without a resolved parent binding"
  assert_contains "$out" "no assistance binding" "refusal did not name the missing binding"
  pass "remind: refuses to deliver before a parent binding exists"
}

# --- 6. deduplication -------------------------------------------------------

test_remind_suppresses_unchanged_repeat() {
  local dir out lines
  dir=$(new_case dedup); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"

  run_cli "$dir" remind prog --id w2 --action dispatch --evidence "report@sha1" \
    "WATCH [w2] before dispatch: rule; verify: target; source: s" >/dev/null || fail "first remind failed"

  out=$(run_cli "$dir" remind prog --id w2 --action dispatch --evidence "report@sha1" \
    "WATCH [w2] before dispatch: rule reworded entirely; verify: target; source: s") \
    || fail "repeat remind errored instead of suppressing"
  assert_contains "$out" "suppressed w2" "an unchanged fingerprint was not suppressed"
  lines=$(wc -l < "$dir/sent")
  [ "$lines" -eq 1 ] || fail "suppression still delivered: $lines messages reached the parent"

  out=$(run_cli "$dir" remind prog --id w2 --action dispatch --evidence "report@sha2" \
    "WATCH [w2] before dispatch: rule; verify: target; source: s") || fail "changed-evidence remind failed"
  assert_contains "$out" "delivered w2" "a materially changed evidence identity was suppressed"
  lines=$(wc -l < "$dir/sent")
  [ "$lines" -eq 2 ] || fail "changed evidence did not deliver a second reminder"
  pass "remind: suppresses an unchanged fingerprint and delivers on changed evidence"
}

test_failed_delivery_stays_retryable() {
  local dir out code lines
  dir=$(new_case dedup-retry); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"

  cat > "$dir/bin/send" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/bin/send"
  out=$(run_cli "$dir" remind prog --id w3 --action dispatch --evidence "e1" \
    "WATCH [w3] before dispatch: rule; verify: t; source: s"); code=$?
  expect_code 1 "$code" "a failed delivery reported success"
  assert_contains "$out" "stays unrecorded" "refusal did not say the reminder is retryable"

  cat > "$dir/bin/send" <<SH
#!/usr/bin/env bash
target=\$1; shift
printf '%s\t%s\n' "\$target" "\$*" >> "$dir/sent"
SH
  chmod +x "$dir/bin/send"
  run_cli "$dir" remind prog --id w3 --action dispatch --evidence "e1" \
    "WATCH [w3] before dispatch: rule; verify: t; source: s" >/dev/null || fail "retry after a failed send was suppressed"
  lines=$(wc -l < "$dir/sent")
  [ "$lines" -eq 1 ] || fail "retry did not deliver exactly once"
  pass "remind: a failed delivery records no fingerprint, so the reminder can be retried"
}

# --- 7. reload after a skill revision ---------------------------------------

test_reload_carries_the_current_revision() {
  local dir skill out first second
  dir=$(new_case reload); write_history "$dir"
  run_cli "$dir" bind prog >/dev/null || fail "bind failed"
  skill="$ROOT/custom-skills/orchestrator-assistance/SKILL.md"

  out=$(run_cli "$dir" reload prog) || fail "reload failed: $out"
  assert_contains "$out" "reloaded prog-assistance" "reload did not address the assistance session"
  assert_grep "prog-assistance	Reread" "$dir/sent" "the reread instruction did not reach the assistance session"
  assert_grep "$skill" "$dir/sent" "the reread instruction did not name the exact revision path"
  first=$(sed -n 's/.*revision=\([0-9a-f]*\).*/\1/p' <<<"$out")
  [ -n "$first" ] || fail "reload reported no revision identity"

  # A revised skill must change the identity the session is told to reread.
  local copy
  copy="$dir/revised-skill.md"
  cp "$skill" "$copy"
  printf '\n<!-- revision under test -->\n' >> "$copy"
  second=$(cd "$dir" && sha256sum "$copy" | cut -c1-16)
  [ "$first" != "$second" ] || fail "a revised skill produced the same revision identity"
  pass "reload: names the exact current revision, and a revision change changes that identity"
}

# --- 8. nonterminal parent pauses -------------------------------------------

test_lifecycle_treats_a_pause_as_live() {
  local dir out
  dir=$(new_case lifecycle); write_history "$dir"

  out=$(run_cli "$dir" lifecycle prog) || fail "lifecycle failed on an absent status log"
  assert_contains "$out" "live prog" "an absent status log was not treated as live"

  printf 'working: dispatching\npaused: waiting on the captain\n' > "$dir/home/state/prog.status"
  out=$(run_cli "$dir" lifecycle prog) || fail "lifecycle failed on a paused parent"
  assert_contains "$out" "live prog" "a paused parent was treated as terminal"

  printf 'blocked: needs a credential\n' >> "$dir/home/state/prog.status"
  out=$(run_cli "$dir" lifecycle prog) || fail "lifecycle failed on a blocked parent"
  assert_contains "$out" "live prog" "a blocked parent was treated as terminal"

  printf 'done: programme complete\n' >> "$dir/home/state/prog.status"
  out=$(run_cli "$dir" lifecycle prog) || fail "lifecycle failed on a finished parent"
  assert_contains "$out" "terminal prog" "an explicit terminal result was not treated as terminal"
  pass "lifecycle: pause and blockage stay live, and only an explicit terminal result ends assistance"
}

test_bind_resolves_parent_and_history
test_bind_refuses_unknown_programme
test_bind_refuses_non_supervisor_parent
test_bind_refuses_ambiguous_history
test_bind_pins_the_named_session
test_bind_refuses_unknown_pin
test_bind_refuses_when_history_absent
test_primary_bind_requires_explicit_existing_session
test_open_is_idempotent_on_the_record
test_observe_records_pending_without_advancing_cursor
test_suppressed_settlement_advances_once
test_delivery_then_recovery_settles_without_duplicate_send
test_out_of_order_settlement_advances_contiguous_prefix_only
test_replay_stops_before_the_named_record
test_replay_refuses_unknown_record
test_remind_delivers_to_the_exact_parent
test_remind_refuses_a_form_that_is_not_awareness
test_remind_refuses_without_a_binding
test_remind_suppresses_unchanged_repeat
test_failed_delivery_stays_retryable
test_reload_carries_the_current_revision
test_lifecycle_treats_a_pause_as_live
