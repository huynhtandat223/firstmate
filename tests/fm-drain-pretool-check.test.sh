#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the drain-and-ack guard (spec huynhtandat223/firstmate#200, E3).
#
# DA1-DA3: bin/fm-drain-command-policy.mjs decides deny, log or allow for the
# exact past commands, and bin/fm-drain-pretool-check.sh turns that into the
# hook answer under the log-only switch (config/enforce-drain-ack).
# DA4: bin/fm-wake-drain.sh refuses an ack while a captain note waits in
# state/inbox/, and accepts the same ack after the note is acked.
# Every case runs in a lab home under a temp root, never the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-drain-pretool-check)

POLICY="$ROOT/bin/fm-drain-command-policy.mjs"
LIVE_HOME_PATH=/home/dathuynh/codes/firstmate

# A primary-shaped checkout: plain git repo, AGENTS.md, bin/ with the wrapper,
# the policy, the shared classifier and the enforce lib.
make_primary() {  # <dir>
  local dir=$1 f
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  for f in fm-drain-pretool-check.sh fm-hook-host-lib.sh fm-drain-command-policy.mjs fm-arm-command-policy.mjs fm-enforce-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-drain-pretool-check.sh" "$dir/bin/fm-drain-command-policy.mjs"
}

policy() {  # <command>: prints the policy answer's first two fields
  node "$POLICY" --command "$1" | cut -f1,2
}

# The commands as firstmate wrote them in past sessions (retro 10-24#5, 10-26#25).
CHAIN_DA1='FM_HOME=$PWD bin/fm-wake-drain.sh --ack-through 56247 --recovery-generation 933164.1791796645.xaIho3 && echo acked; FM_HOME=$PWD bin/fm-wake-drain.sh 2>&1 | grep -o '"'"'...'"'"' | sh'
CHAIN_DA2='F='"$LIVE_HOME_PATH"'; $F/bin/fm-wake-drain.sh 2>&1 | head -2 | cut -c1-250; $F/bin/fm-wake-drain.sh --ack-through 56157 --recovery-generation 1229022.1791774409.hKpOhf'

test_da1_da2_the_past_chains_are_denied() {
  [ "$(policy "$CHAIN_DA1")" = "$(printf 'deny\tchained-ack')" ] || fail "DA1 chain not denied: $(policy "$CHAIN_DA1")"
  [ "$(policy "$CHAIN_DA2")" = "$(printf 'deny\tchained-ack')" ] || fail "DA2 chain not denied: $(policy "$CHAIN_DA2")"
  pass "DA1 and DA2: the two past ack-and-drain chains are denied"
}

test_chain_shapes_are_denied() {
  local cmd ack='bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g.1'
  for cmd in \
    "bin/fm-wake-drain.sh; $ack" \
    "bin/fm-wake-drain.sh && $ack" \
    "$ack && bin/fm-wake-drain.sh" \
    "bin/fm-wake-drain.sh | head -3; $ack" \
    "echo \$(bin/fm-wake-drain.sh); $ack" \
    "(bin/fm-wake-drain.sh); $ack" \
    "{ bin/fm-wake-drain.sh; }; $ack" \
    "bash bin/fm-wake-drain.sh; bash $ack" \
    "FM_HOME=/x /abs/bin/fm-wake-drain.sh; FM_HOME=/x /abs/$ack" \
    "$ack; $ack" \
    "bash -c 'bin/fm-wake-drain.sh; $ack'" \
    "sh -c \"bin/fm-wake-drain.sh && $ack\"" \
    "bash -lc 'bin/fm-wake-drain.sh; $ack'" \
    "if bin/fm-wake-drain.sh; then $ack; fi" \
    "while bin/fm-wake-drain.sh; do $ack; done" \
    "until false; do bin/fm-wake-drain.sh; $ack; done" \
    "! bin/fm-wake-drain.sh || $ack" \
    "case x in x) bin/fm-wake-drain.sh; $ack;; esac" \
    $'case x in\n x)\n  bin/fm-wake-drain.sh\n  '"$ack"$'\n  ;;\nesac'; do
    [ "$(policy "$cmd")" = "$(printf 'deny\tchained-ack')" ] || fail "chain not denied: $cmd => $(policy "$cmd")"
  done
  pass "an ack joined to another drain by ;, &&, a pipe, a subshell, a group or \$() is denied; so is one inside bash -c, if/while/until bodies and case arms"
}

test_da3_alone_and_source_reads_are_allowed() {
  local cmd
  for cmd in \
    'bin/fm-wake-drain.sh' \
    'FM_HOME=$PWD bin/fm-wake-drain.sh' \
    'bin/fm-wake-drain.sh --ack-through 56247 --recovery-generation 933164.1791796645.xaIho3' \
    'FM_HOME=$PWD bin/fm-wake-drain.sh --ack-through 5 --recovery-generation a.b' \
    'grep -n x bin/fm-wake-drain.sh' \
    'cat bin/fm-wake-drain.sh' \
    'sed -n 1,20p bin/fm-wake-drain.sh' \
    'bash -n bin/fm-wake-drain.sh; bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g' \
    'echo "bin/fm-wake-drain.sh --ack-through 1"; bin/fm-wake-drain.sh' \
    "bash -c 'bin/fm-wake-drain.sh'" \
    "bash -c 'grep -n x bin/fm-wake-drain.sh'" \
    "if true; then bin/fm-wake-drain.sh; fi" \
    "case x in x) bin/fm-wake-drain.sh;; esac" \
    'ls bin; git status'; do
    [ "$(policy "$cmd")" = allow ] || fail "must allow: $cmd => $(policy "$cmd")"
  done
  pass "DA3: a drain alone, an ack alone and a read of the script source are allowed"
}

# Issue #205: a drain in each then/else branch or case arm runs once, so it is no chain.
test_exclusive_if_branches_are_not_a_chain() {
  local cmd ack='bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g'
  for cmd in \
    "if true; then bin/fm-wake-drain.sh; else $ack; fi" \
    "if true; then $ack; else bin/fm-wake-drain.sh; fi" \
    "if true; then bin/fm-wake-drain.sh; elif false; then $ack; else bin/fm-wake-drain.sh; fi" \
    $'if true\nthen\n  bin/fm-wake-drain.sh\nelse\n  '"$ack"$'\nfi' \
    "if true; then if false; then bin/fm-wake-drain.sh; else $ack; fi; fi" \
    "bash -c 'if true; then bin/fm-wake-drain.sh; else $ack; fi'"; do
    [ "$(policy "$cmd")" = allow ] || fail "#205 exclusive if branches must allow: $cmd => $(policy "$cmd")"
  done
  for cmd in \
    "if bin/fm-wake-drain.sh; then $ack; fi" \
    "if true; then bin/fm-wake-drain.sh; else bin/fm-wake-drain.sh; fi; $ack" \
    "if true; then bin/fm-wake-drain.sh; $ack; else true; fi" \
    "if true; then bin/fm-wake-drain.sh; elif bin/fm-wake-drain.sh; then $ack; fi" \
    "if true; then true; else bin/fm-wake-drain.sh; $ack; fi" \
    "if true; then true; fi; bin/fm-wake-drain.sh; if true; then $ack; else true; fi"; do
    [ "$(policy "$cmd")" = "$(printf 'deny\tchained-ack')" ] || fail "#205 a real chain must still be denied: $cmd => $(policy "$cmd")"
  done
  pass "#205: a drain and an ack in exclusive then/else branches are allowed; a chain on one path is still denied"
}

# Reader round 1 on PR 220: an elif condition runs before every later branch.
test_elif_condition_shares_the_later_branches() {
  local cmd ack='bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g'
  for cmd in \
    "if true; then $ack; elif bin/fm-wake-drain.sh; then true; fi" \
    "if true; then bin/fm-wake-drain.sh; elif true; then $ack; fi" \
    "if true; then $ack; elif ! bin/fm-wake-drain.sh; then true; fi"; do
    [ "$(policy "$cmd")" = allow ] || fail "an elif condition is exclusive with the earlier bodies, must allow: $cmd => $(policy "$cmd")"
  done
  for cmd in \
    "if false; then true; elif ! bin/fm-wake-drain.sh; then true; else $ack; fi" \
    "if false; then true; elif bin/fm-wake-drain.sh; then true; elif true; then $ack; fi" \
    "if false; then true; elif bin/fm-wake-drain.sh; then $ack; fi" \
    "if false; then true; elif $ack; then true; else bin/fm-wake-drain.sh; fi" \
    "if bin/fm-wake-drain.sh; then true; elif true; then $ack; fi"; do
    [ "$(policy "$cmd")" = "$(printf 'deny\tchained-ack')" ] || fail "an elif condition runs before every later branch, must deny: $cmd => $(policy "$cmd")"
  done
  pass "an elif condition shares the path of every later branch and is exclusive only with the earlier bodies"
}

test_exclusive_case_arms_are_not_a_chain() {
  local cmd ack='bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g'
  for cmd in \
    "case x in x) bin/fm-wake-drain.sh;; y) $ack;; esac" \
    "case x in x|z) $ack;; *) bin/fm-wake-drain.sh;; esac" \
    $'case x in\n x)\n  bin/fm-wake-drain.sh\n  ;;\n y)\n  '"$ack"$'\n  ;;\nesac' \
    "case x in x) if true; then bin/fm-wake-drain.sh; fi;; y) $ack;; esac"; do
    [ "$(policy "$cmd")" = allow ] || fail "#205 exclusive case arms must allow: $cmd => $(policy "$cmd")"
  done
  for cmd in \
    "case x in x) bin/fm-wake-drain.sh; $ack;; y) true;; esac" \
    "case x in x) true;; esac; bin/fm-wake-drain.sh; case y in y) $ack;; esac" \
    "case x in x) bin/fm-wake-drain.sh;; y) true;; esac && $ack" \
    "bin/fm-wake-drain.sh; case x in x) true;; y) $ack;; esac" \
    "bash -c 'if true; then true; else bin/fm-wake-drain.sh; fi'; bash -c 'if true; then true; else $ack; fi'"; do
    [ "$(policy "$cmd")" = "$(printf 'deny\tchained-ack')" ] || fail "#205 a real chain around a case must still be denied: $cmd => $(policy "$cmd")"
  done
  pass "#205: a drain and an ack in different case arms are allowed; a chain on one path is still denied"
}

test_no_exec_shells_classify_nothing() {
  local cmd ack='bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g'
  for cmd in \
    "bash -nc 'bin/fm-wake-drain.sh; $ack'" \
    "bash -n -c 'bin/fm-wake-drain.sh; $ack'" \
    "sh -nc \"bin/fm-wake-drain.sh && $ack\"" \
    "bash -ncx 'bin/fm-wake-drain.sh; $ack'" \
    "bash -o noexec -c 'bin/fm-wake-drain.sh; $ack'"; do
    [ "$(policy "$cmd")" = allow ] || fail "#205 a no-exec shell must classify nothing: $cmd => $(policy "$cmd")"
  done
  for cmd in \
    "bash -c 'bin/fm-wake-drain.sh; $ack'" \
    "bash -xc 'bin/fm-wake-drain.sh; $ack'" \
    "bash -nc 'true'; bin/fm-wake-drain.sh; $ack"; do
    [ "$(policy "$cmd")" = "$(printf 'deny\tchained-ack')" ] || fail "#205 an executing shell must still be classified: $cmd => $(policy "$cmd")"
  done
  pass "#205: bash -n and bash -nc execute nothing and classify nothing; bash -c still does"
}

test_da3_a_filtered_drain_is_logged_not_denied() {
  local cmd
  for cmd in \
    'bin/fm-wake-drain.sh | grep -n ready' \
    'bin/fm-wake-drain.sh 2>&1 | head -2' \
    'bin/fm-wake-drain.sh | cut -c1-200' \
    'bin/fm-wake-drain.sh | sed -n 1,5p'; do
    [ "$(policy "$cmd")" = "$(printf 'log\tfiltered-drain')" ] || fail "must log: $cmd => $(policy "$cmd")"
  done
  pass "DA3: a drain piped into grep, head, cut or sed alone is a log decision"
}

run_check() {  # <dir> <command> ...: the wrapper in --claude stdin form; sets RC, OUT, ERR
  local dir=$1 cmd=$2
  OUT=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | FM_HOME="$dir" "$dir/bin/fm-drain-pretool-check.sh" --claude 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
}

test_hook_logs_only_until_the_switch_is_set() {
  local dir="$TMP_ROOT/hook-log" log
  make_primary "$dir"
  run_check "$dir" "$CHAIN_DA1"
  [ "$RC" -eq 0 ] || fail "log-only default must allow, got exit $RC: $ERR"
  [ -z "$OUT$ERR" ] || fail "log-only default must be silent: $OUT $ERR"
  log="$dir/state/enforce-drain-ack.log"
  [ -f "$log" ] || fail "log-only default wrote no hit log"
  grep -q 'would-deny	chained-ack	' "$log" || fail "hit log lacks the would-deny line: $(cat "$log")"
  printf '# block after the day of review\nlog\n' > "$dir/config/enforce-drain-ack"
  run_check "$dir" "$CHAIN_DA1"
  [ "$RC" -eq 0 ] || fail "a config of log must still allow"
  pass "DA1: with config/enforce-drain-ack absent or log the chain is allowed and written to state/enforce-drain-ack.log"
}

test_hook_denies_in_block_mode() {
  local dir="$TMP_ROOT/hook-block"
  make_primary "$dir"
  printf 'block\n' > "$dir/config/enforce-drain-ack"
  run_check "$dir" "$CHAIN_DA1"
  [ "$RC" -eq 2 ] || fail "block mode must deny the DA1 chain, got exit $RC"
  [ -z "$OUT" ] || fail "claude deny must leave stdout empty: $OUT"
  printf '%s' "$ERR" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("run the drain alone, read every row, then run WAKE_ACK_REQUIRED exactly as printed"))' >/dev/null \
    || fail "deny answer lacks the fix text: $ERR"
  printf '%s\n' "$ERR" > "$TMP_ROOT/da1-hook-answer.json"
  run_check "$dir" "$CHAIN_DA2"
  [ "$RC" -eq 2 ] || fail "block mode must deny the DA2 chain, got exit $RC"
  run_check "$dir" 'bin/fm-wake-drain.sh'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a drain alone must pass in block mode"
  run_check "$dir" 'grep -n x bin/fm-wake-drain.sh'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "reading the source must pass in block mode"
  run_check "$dir" 'bin/fm-wake-drain.sh 2>&1 | head -2'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a filtered drain must be logged, not denied, in block mode"
  grep -q '	log	filtered-drain	' "$dir/state/enforce-drain-ack.log" || fail "the piped drain was not logged: $(cat "$dir/state/enforce-drain-ack.log")"
  pass "DA1, DA2, DA3: in block mode both chains are denied with the fix text; a lone drain and a source read pass; a piped drain is logged"
}

test_hook_is_inert_in_a_task_worktree_and_fails_open() {
  local base="$TMP_ROOT/inert-base" wt="$TMP_ROOT/inert-wt"
  make_primary "$base"
  fm_git_worktree "$base" "$wt" fm/drain-guard-test
  : > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$wt/config" "$wt/state"
  cp "$base"/bin/* "$wt/bin/"
  printf 'block\n' > "$wt/config/enforce-drain-ack"
  run_check "$wt" "$CHAIN_DA1"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a task worktree must be inert, got exit $RC: $ERR"
  printf 'not json' | FM_HOME="$base" "$base/bin/fm-drain-pretool-check.sh" --claude 2>/dev/null \
    || fail "malformed stdin must fail open"
  pass "the hook is inert in a task worktree and fails open on malformed input"
}

# --- DA4: the ack refusal in bin/fm-wake-drain.sh ------------------------------

lab_drain() {  # <dir> [ack args...]
  local d=$1
  shift
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" "$ROOT/bin/fm-wake-drain.sh" "$@" 2>"$d/err"
}

lab_ack_args() {  # <dir>: prints "<seq> <generation>" from the drain's WAKE_ACK_REQUIRED line
  sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$1/err" | tail -1
}

test_da4_ack_refused_while_a_captain_note_waits() {
  local dir="$TMP_ROOT/da4" seq gen note=1793248017-aI7HFO
  mkdir -p "$dir/state/inbox" "$dir/config"
  printf '%s\t1\tcheck\tprobe-key\tcheck: probe\n' "$(date +%s)" >> "$dir/state/.wake-queue"
  printf 'schema=note\n--\nplease look at this\n' > "$dir/state/inbox/$note.note"
  printf 'block\n' > "$dir/config/enforce-drain-ack"
  lab_drain "$dir" > "$dir/out"
  read -r seq gen <<< "$(lab_ack_args "$dir")"
  [ -n "$seq" ] && [ -n "$gen" ] || fail "DA4 no ack boundary in the drain: $(cat "$dir/err")"
  if lab_drain "$dir" --ack-through "$seq" --recovery-generation "$gen" > "$dir/out2"; then
    fail "DA4 the ack was accepted while a captain note waits"
  fi
  grep -F "captain note $note waits; handle it, then fm-inbox.sh drain --ack $note" "$dir/err" >/dev/null \
    || fail "DA4 refusal text: $(cat "$dir/err")"
  cp "$dir/err" "$TMP_ROOT/da4-refusal.txt"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-inbox.sh" drain --ack "$note" > "$dir/ackout"
  grep -q "acked $note" "$dir/ackout" || fail "DA4 the note was not acked: $(cat "$dir/ackout")"
  # The exact refused sequence and generation, with no new drain in between.
  lab_drain "$dir" --ack-through "$seq" --recovery-generation "$gen" > "$dir/out4" \
    || fail "DA4 the same ack was refused after the note was acked: $(cat "$dir/err")"
  cp "$dir/out4" "$TMP_ROOT/da4-accepted.txt"
  pass "DA4: the ack is refused naming the note, and succeeds once fm-inbox.sh drain --ack handled it"
}

test_da4_logs_only_until_the_switch_is_set() {
  local dir="$TMP_ROOT/da4-log" seq gen note=1793248107-tfNEgn
  mkdir -p "$dir/state/inbox" "$dir/config"
  printf '%s\t1\tcheck\tprobe-key\tcheck: probe\n' "$(date +%s)" >> "$dir/state/.wake-queue"
  printf 'schema=note\n--\nsecond note\n' > "$dir/state/inbox/$note.note"
  lab_drain "$dir" > "$dir/out"
  read -r seq gen <<< "$(lab_ack_args "$dir")"
  lab_drain "$dir" --ack-through "$seq" --recovery-generation "$gen" > "$dir/out2" \
    || fail "log-only default must accept the ack: $(cat "$dir/err")"
  grep -q "would-refuse	waiting-captain-note	$note" "$dir/state/enforce-drain-ack.log" \
    || fail "log-only default wrote no would-refuse line: $(cat "$dir/state/enforce-drain-ack.log" 2>&1)"
  pass "DA4: with config/enforce-drain-ack absent the ack passes and the would-be refusal is logged"
}

test_claude_settings_register_the_drain_guard() {
  local dir="$TMP_ROOT/wiring" cmd payload rc
  make_primary "$dir"
  printf 'block\n' > "$dir/config/enforce-drain-ack"
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("fm-drain-pretool-check.sh"))' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "PreToolUse Bash has no fm-drain-pretool-check.sh entry in .claude/settings.json"
  payload=$(jq -cn --arg c "$CHAIN_DA1" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$dir" FM_HOME="$dir" bash -c "$cmd" >/dev/null 2>"$dir/err"
  rc=$?
  [ "$rc" -eq 2 ] || fail "the registered settings command did not deny the DA1 chain: $(cat "$dir/err")"
  pass "the command registered in .claude/settings.json runs the guard and denies the DA1 chain in block mode"
}

test_da1_da2_the_past_chains_are_denied
test_chain_shapes_are_denied
test_da3_alone_and_source_reads_are_allowed
test_exclusive_if_branches_are_not_a_chain
test_exclusive_case_arms_are_not_a_chain
test_elif_condition_shares_the_later_branches
test_no_exec_shells_classify_nothing
test_da3_a_filtered_drain_is_logged_not_denied
test_hook_logs_only_until_the_switch_is_set
test_hook_denies_in_block_mode
test_hook_is_inert_in_a_task_worktree_and_fails_open
test_claude_settings_register_the_drain_guard
test_da4_ack_refused_while_a_captain_note_waits
test_da4_logs_only_until_the_switch_is_set

echo "# fm-drain-pretool-check.test.sh: all assertions passed"
