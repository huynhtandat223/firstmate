#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the captain reply lint (spec huynhtandat223/firstmate#200, E2).
#
# bin/fm-reply-lint.sh is the Stop-hook transport and bin/fm-reply-lint.mjs the
# checks. Every case runs in a lab home under a temp root with fixture
# transcripts shaped like Claude's JSONL, never the live home:
#   RL3  a Vietnamese reply passes; an English reply, and a `?` with no
#        agent-ask call in the turn, are flagged; a `?` after an agent-ask call
#        passes; a turn already blocked once is not blocked again; no
#        config/reply-language means the lint does nothing.
#   RL4  two captain notes waiting in state/inbox/ block "Captain, mọi thứ ổn."
#        once and name both note ids.
#   RL5  a session that never read data/captain.md since its last SessionStart
#        is blocked once, naming data/captain.md and the handoff to read.
# Each hit is log-only until config/enforce-reply-lint holds `block`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-reply-lint)

LINT_FILES="fm-reply-lint.sh fm-reply-lint.mjs fm-hook-host-lib.sh fm-primary-scope-lib.sh fm-enforce-lib.sh"

make_primary() {  # <dir> [block]
  local dir=$1 f
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin" "$dir/state/inbox" "$dir/config" "$dir/data/handoffs"
  for f in $LINT_FILES; do cp "$ROOT/bin/$f" "$dir/bin/$f"; done
  chmod +x "$dir/bin/fm-reply-lint.sh"
  printf 'vi\n' > "$dir/config/reply-language"
  [ "${2:-}" != block ] || printf 'block\n' > "$dir/config/enforce-reply-lint"
  printf '# Captain preferences\n\n**Start here:** after the digest, follow the newest handoff, `data/handoffs/latest.md`.\n' > "$dir/data/captain.md"
}

# Transcript builders: one JSON object per line.
t_session_start() {  # <file> <in-reach|late|spill>: a SessionStart digest with captain.md early or late
  local file=$1 mode=$2 digest i
  digest=$'RE-EMIT CUE: if this output ends with "Output too large ... Full output saved to <path>",\nread that whole file now, before acting.\n'
  if [ "$mode" = spill ]; then
    digest=$'<persisted-output>\nOutput too large (78KB). Full output saved to: /x/tool-results/hook.txt\n\nPreview (first 2KB):\n'"$digest"
    digest+=$'data/captain.md\n--------------------------------------------------------------------------------\nrules\n'
  elif [ "$mode" = in-reach ]; then
    digest+=$'data/captain.md\n--------------------------------------------------------------------------------\nrules\n'
  else
    for i in $(seq 1 600); do digest+="filler line $i"$'\n'; done
    digest+=$'data/captain.md\n--------------------------------------------------------------------------------\nrules\n'
  fi
  jq -cn --arg d "$digest" '{type:"attachment",uuid:"ss",attachment:{type:"hook_success",hookEvent:"SessionStart",hookName:"SessionStart:clear",stdout:$d}}' >> "$file"
}
t_tool() {  # <file> <name> <input-json>
  jq -cn --arg n "$2" --argjson i "$3" '{type:"assistant",uuid:("tool-"+$n),message:{stop_reason:"tool_use",content:[{type:"tool_use",name:$n,input:$i}]}}' >> "$1"
}
t_reply() {  # <file> <uuid> <text>
  jq -cn --arg u "$2" --arg t "$3" '{type:"assistant",uuid:$u,timestamp:"2026-10-29T00:00:00Z",message:{stop_reason:"end_turn",content:[{type:"text",text:$t}]}}' >> "$1"
}

stop() {  # <dir> <transcript> [stop_hook_active]: runs the hook; sets RC and ERR
  local dir=$1 transcript=$2 active=${3:-false}
  ERR=$(jq -cn --arg t "$transcript" --argjson a "$active" --arg s "${STOP_SESSION:-s1}" --arg l "${STOP_LAST_TEXT:-}" \
    '{hook_event_name:"Stop",transcript_path:$t,stop_hook_active:$a,session_id:$s} + (if $l == "" then {} else {last_assistant_message:$l} end)' \
    | env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE "$dir/bin/fm-reply-lint.sh" --claude 2>&1 >/dev/null)
  RC=$?
}

VI_REPLY='Captain, em đã xử lý xong và mọi thứ đang chạy bình thường.'
EN_REPLY='Captain, everything is shipshape and the worker is on track.'
VI_QUESTION='Captain, anh muốn em chạy song song hay lần lượt?'

test_rl3_vietnamese_passes_english_is_flagged() {
  local dir="$TMP_ROOT/rl3-lang" tr
  make_primary "$dir" block
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a Vietnamese reply must pass, got exit $RC: $ERR"
  t_reply "$tr" r2 "$EN_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "an English reply must block, got exit $RC"
  assert_contains "$ERR" "captain.md:16: resend in Vietnamese, technical terms stay English" "the English block lacks its fix text"
  pass "RL3: a Vietnamese reply passes and an English reply is blocked with the captain.md:16 fix"
}

test_rl3_question_needs_agent_ask() {
  local dir="$TMP_ROOT/rl3-ask" tr
  make_primary "$dir" block
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$VI_QUESTION"
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "a question with no agent-ask call must block, got exit $RC"
  assert_contains "$ERR" "captain.md:20: post it with agent-ask (FM_TASK_ID, AGENT_ASK_ASKER=firstmate); chat carries its id" "the question block lacks its fix text"
  t_tool "$tr" Bash '{"command":"FM_TASK_ID=x AGENT_ASK_ASKER=firstmate agent-ask post --board ..."}'
  t_reply "$tr" r2 "$VI_QUESTION"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a question after an agent-ask call in the same turn must pass, got exit $RC: $ERR"
  pass "RL3: a ? blocks without an agent-ask call in the turn and passes after one"
}

test_rl3_blocked_once_per_turn() {
  local dir="$TMP_ROOT/rl3-once" tr
  make_primary "$dir" block
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$EN_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "the first stop must block, got exit $RC"
  t_reply "$tr" r2 "$EN_REPLY, still English."
  stop "$dir" "$tr" true
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "the second stop of the same turn must not block, got exit $RC: $ERR"
  t_reply "$tr" r3 "A later turn in English again, with no Vietnamese at all."
  stop "$dir" "$tr" false
  [ "$RC" -eq 2 ] || fail "a later turn must be linted again, got exit $RC"
  pass "RL3: a turn already blocked once is not blocked a second time, a later turn is linted again"
}

test_rl3_absent_config_does_nothing() {
  local dir="$TMP_ROOT/rl3-off" tr
  make_primary "$dir" block
  rm -f "$dir/config/reply-language"
  tr="$dir/t.jsonl"
  t_session_start "$tr" late
  t_reply "$tr" r1 "$EN_REPLY?"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "without config/reply-language the lint must do nothing, got exit $RC: $ERR"
  [ ! -e "$dir/state/enforce-reply-lint.log" ] || fail "the lint logged without config/reply-language"
  pass "RL3: with config/reply-language absent the lint does nothing"
}

test_log_only_until_the_switch_is_set() {
  local dir="$TMP_ROOT/log-only" tr
  make_primary "$dir"
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$EN_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "log-only must not block, got exit $RC: $ERR"
  grep -q 'would-block	english	' "$dir/state/enforce-reply-lint.log" || fail "log-only wrote no would-block line: $(cat "$dir/state/enforce-reply-lint.log" 2>&1)"
  [ -z "$(find "$dir/state" -maxdepth 1 -name ".reply-lint-blocked*")" ] || fail "log-only recorded a block"
  pass "log-only: with config/enforce-reply-lint absent a hit is logged and nothing is blocked"
}

test_rl4_waiting_notes_block_once_naming_both() {
  local dir="$TMP_ROOT/rl4" tr
  make_primary "$dir" block
  printf 'schema=note\n--\nfirst\n' > "$dir/state/inbox/1793248017-aI7HFO.note"
  printf 'schema=note\n--\nsecond\n' > "$dir/state/inbox/1793248107-tfNEgn.note"
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "Captain, mọi thứ ổn."
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "two waiting notes must block, got exit $RC"
  assert_contains "$ERR" "2 captain notes wait: handle them first" "the notes block lacks its headline"
  assert_contains "$ERR" "1793248017-aI7HFO" "the notes block does not name the first note"
  assert_contains "$ERR" "1793248107-tfNEgn" "the notes block does not name the second note"
  printf '%s\n' "$ERR" > "$TMP_ROOT/rl4-block.txt"
  t_reply "$tr" r2 "Captain, em sẽ xử lý hai ghi chú ngay."
  stop "$dir" "$tr" true
  [ "$RC" -eq 0 ] || fail "the same turn must not be blocked twice, got exit $RC: $ERR"
  pass "RL4: two waiting captain notes block \"Captain, mọi thứ ổn.\" once and name both ids"
}

test_rl5_unread_captain_md_blocks_once() {
  local dir="$TMP_ROOT/rl5" tr
  make_primary "$dir" block
  tr="$dir/t.jsonl"
  t_session_start "$tr" late
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "a reply before reading captain.md must block, got exit $RC"
  assert_contains "$ERR" "data/captain.md" "the unread block does not name data/captain.md"
  assert_contains "$ERR" "data/handoffs/latest.md" "the unread block does not name the handoff"
  t_reply "$tr" r2 "$VI_REPLY"
  stop "$dir" "$tr" true
  [ "$RC" -eq 0 ] || fail "the same turn must not be blocked twice, got exit $RC: $ERR"
  t_tool "$tr" Read '{"file_path":"/x/data/captain.md"}'
  t_reply "$tr" r3 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "after a Read of data/captain.md the reply must pass, got exit $RC: $ERR"
  pass "RL5: a reply before data/captain.md was read blocks once naming the file and handoff; a Read clears it"
}

test_rl5_reach_digest_and_shell_read_count() {
  local dir="$TMP_ROOT/rl5-reach" tr
  make_primary "$dir" block
  tr="$dir/in-reach.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a digest that holds captain.md in reach must satisfy the rule, got exit $RC: $ERR"
  tr="$dir/cat.jsonl"
  t_session_start "$tr" late
  t_tool "$tr" Bash '{"command":"cat data/captain.md"}'
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a cat of data/captain.md must satisfy the rule, got exit $RC: $ERR"
  tr="$dir/older.jsonl"
  t_session_start "$tr" late
  t_tool "$tr" Read '{"file_path":"/x/data/captain.md"}'
  t_session_start "$tr" late
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "a read before the LAST SessionStart must not count, got exit $RC"
  pass "RL5: a digest with captain.md in reach or a shell read satisfies it; a read before the last SessionStart does not"
}

test_rl5_real_reemit_digest_is_not_a_spill() {
  local dir="$TMP_ROOT/rl5-cue" tr
  make_primary "$dir" block
  tr="$dir/real.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a re-emit digest whose cue says 'Output too large' is not a spill, got exit $RC: $ERR"
  tr="$dir/spill.jsonl"
  t_session_start "$tr" spill
  t_reply "$tr" r1 "$VI_REPLY"
  stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "a persisted-output spill notice must not count as a read, got exit $RC"
  pass "RL5: the RE-EMIT CUE text is not mistaken for a spill; a real persisted-output notice is"
}

test_session_keyed_block_record() {
  local dir="$TMP_ROOT/session-key" tr
  make_primary "$dir" block
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$EN_REPLY"
  STOP_SESSION=sA stop "$dir" "$tr"
  [ "$RC" -eq 2 ] || fail "session A's first stop must block, got exit $RC"
  t_reply "$tr" r2 "$EN_REPLY, again."
  STOP_SESSION=sB stop "$dir" "$tr" true
  [ "$RC" -eq 2 ] || fail "session B must not inherit session A's block record, got exit $RC"
  t_reply "$tr" r3 "$EN_REPLY, a third time."
  STOP_SESSION=sB stop "$dir" "$tr" true
  [ "$RC" -eq 0 ] || fail "session B's own follow-up stop must pass, got exit $RC: $ERR"
  [ ! -e "$dir/state/.reply-lint-blocked" ] || fail "the old single shared block file is still written"
  pass "the block record is kept per session_id"
}




test_inert_in_a_task_worktree_and_fails_open() {
  local base="$TMP_ROOT/inert-base" wt="$TMP_ROOT/inert-wt" tr
  make_primary "$base" block
  fm_git_worktree "$base" "$wt" fm/reply-lint-test
  : > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$wt/state" "$wt/config"
  cp "$base"/bin/* "$wt/bin/"
  cp "$base/config/"* "$wt/config/"
  tr="$wt/t.jsonl"
  t_reply "$tr" r1 "$EN_REPLY"
  stop "$wt" "$tr"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a task worktree must be inert, got exit $RC: $ERR"
  printf 'not json' | "$base/bin/fm-reply-lint.sh" --claude 2>/dev/null || fail "malformed stdin must fail open"
  stop "$base" "$TMP_ROOT/does-not-exist.jsonl"
  [ "$RC" -eq 0 ] || fail "a missing transcript must fail open, got exit $RC"
  pass "the lint is inert in a task worktree and fails open on bad input"
}

test_claude_settings_register_the_lint() {
  local dir="$TMP_ROOT/wiring" cmd tr rc
  make_primary "$dir" block
  cmd=$(jq -r '.hooks.Stop[].hooks[].command | select(contains("fm-reply-lint.sh"))' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "the Stop hooks in .claude/settings.json have no fm-reply-lint.sh entry"
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$EN_REPLY"
  jq -cn --arg t "$tr" '{hook_event_name:"Stop",transcript_path:$t,stop_hook_active:false,session_id:"s1"}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT -u FM_HOME CLAUDE_PROJECT_DIR="$dir" bash -c "$cmd" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "the command registered in .claude/settings.json did not block an English reply, got exit $rc"
  pass "the command registered in .claude/settings.json runs the lint and blocks an English reply in block mode"
}

test_replay_lists_flagged_turns() {
  local dir="$TMP_ROOT/replay" tr out
  make_primary "$dir"
  tr="$dir/t.jsonl"
  t_session_start "$tr" in-reach
  t_reply "$tr" r1 "$VI_REPLY"
  t_reply "$tr" r2 "$EN_REPLY"
  t_reply "$tr" r3 "$VI_QUESTION"
  out=$("$dir/bin/fm-reply-lint.sh" --replay "$tr")
  assert_contains "$out" "english" "the replay did not flag the English turn"
  assert_contains "$out" "question" "the replay did not flag the question turn"
  assert_contains "$out" "3 turn ends, 2 flagged" "the replay summary is wrong"
  pass "replay: lists the flagged turn ends and a summary"
}

test_rl3_vietnamese_passes_english_is_flagged
test_rl3_question_needs_agent_ask
test_rl3_blocked_once_per_turn
test_rl3_absent_config_does_nothing
test_log_only_until_the_switch_is_set
test_rl4_waiting_notes_block_once_naming_both
test_rl5_unread_captain_md_blocks_once
test_rl5_reach_digest_and_shell_read_count
test_rl5_real_reemit_digest_is_not_a_spill
test_session_keyed_block_record
test_inert_in_a_task_worktree_and_fails_open
test_claude_settings_register_the_lint
test_replay_lists_flagged_turns

echo "# fm-reply-lint.test.sh: all assertions passed"
