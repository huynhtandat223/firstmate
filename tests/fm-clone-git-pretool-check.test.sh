#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the project-clone git guard (spec huynhtandat223/firstmate#200, E10).
#
# CG1, CG2: bin/fm-clone-git-command-policy.mjs decides deny or allow for the
# exact past commands, and bin/fm-clone-git-pretool-check.sh turns that into the
# hook answer under the log-only switch (config/enforce-clone-git).
# CG3: --replay lists the denied commands of a transcript with their session id.
# Every case runs in a lab home under a temp root, never the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-clone-git-pretool-check)

POLICY="$ROOT/bin/fm-clone-git-command-policy.mjs"
HOME_PATH=/home/dathuynh/codes/firstmate

# A primary-shaped checkout: plain git repo, AGENTS.md, bin/ with the wrapper,
# the policy, the walker, the shared classifier and the enforce lib.
make_primary() {  # <dir>
  local dir=$1 f
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin" "$dir/state" "$dir/config" "$dir/projects"
  for f in fm-clone-git-pretool-check.sh fm-hook-host-lib.sh fm-clone-git-command-policy.mjs fm-shell-walk-lib.mjs fm-arm-command-policy.mjs fm-enforce-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-clone-git-pretool-check.sh" "$dir/bin/fm-clone-git-command-policy.mjs"
}

policy() {  # <command>: the policy answer's first two fields, read against the live home path
  node "$POLICY" --home "$HOME_PATH" --command "$1" | cut -f1,2
}

# The commands as firstmate wrote them in past sessions (report E10).
CG1_CMD='git -C projects/cfw-modules fetch -q origin pull/1699/head'
CG2_CMD_A='git -C projects/cfw-modules fetch -q origin main && git -C projects/cfw-modules merge --ff-only -q origin/main'
CG2_CMD_B='git -C projects/cfw-modules show origin/main:README.md'

test_cg1_the_past_pr_fetch_is_denied() {
  local out
  out=$(node "$POLICY" --home "$HOME_PATH" --command "$CG1_CMD")
  [ "$(printf '%s' "$out" | cut -f1,2)" = "$(printf 'deny\tgit-fetch-refspec')" ] || fail "CG1 not denied: $out"
  printf '%s' "$out" | grep -q 'gh pr diff <n>' || fail "CG1 reason lacks gh pr diff: $out"
  printf '%s' "$out" | grep -q 'git -C <worker worktree>' || fail "CG1 reason lacks the worker worktree form: $out"
  pass "CG1: fetch of pull/1699/head into a clone is denied, naming gh pr diff and git -C <worker worktree>"
}

test_cg2_the_sanctioned_forms_are_allowed() {
  local cmd
  for cmd in \
    "$CG2_CMD_A" \
    "$CG2_CMD_B" \
    'git -C projects/cfw-modules fetch origin' \
    'git -C projects/cfw-modules fetch -q origin main' \
    'git -C projects/cfw-modules fetch --prune origin' \
    'git -C projects/cfw-modules merge --ff-only origin/main' \
    'git -C projects/cfw-modules log --oneline -5 origin/main' \
    'git -C projects/cfw-modules diff origin/main...origin/feature' \
    'git -C projects/cfw-modules grep -n foo origin/main -- src' \
    'git -C projects/cfw-modules ls-tree -r origin/main --name-only' \
    'git -C projects/cfw-modules status --short' \
    'git -C projects/cfw-modules rev-parse --short origin/main' \
    'git -C projects/cfw-modules branch -a' \
    'git -C projects/cfw-modules branch --list "fm/*"' \
    'git -C projects/cfw-modules worktree list' \
    'git -C projects/cfw-modules remote -v' \
    'git -C projects/cfw-modules stash list' \
    'git -C projects/cfw-modules stash show -p stash@{0}' \
    'git -C projects/cfw-modules cat-file -p origin/main:README.md'; do
    [ "$(policy "$cmd")" = allow ] || fail "must allow: $cmd => $(policy "$cmd")"
  done
  pass "CG2: fetch of a remote or branch, merge --ff-only and every read of a clone are allowed"
}

test_state_changing_verbs_are_denied() {
  local cmd
  for cmd in \
    'git -C projects/x fetch -q origin pull/1/head:refs/fm/pr1' \
    "git -C projects/x fetch origin 'refs/pull/1/head:refs/remotes/pr/1'" \
    'git -C projects/x fetch origin main:main' \
    'git -C projects/x fetch origin +refs/heads/*:refs/remotes/origin/*' \
    'git -C projects/x pull' \
    'git -C projects/x pull --ff-only' \
    'git -C projects/x checkout main' \
    'git -C projects/x switch -c topic' \
    'git -C projects/x reset --hard origin/main' \
    'git -C projects/x commit -m x' \
    'git -C projects/x stash' \
    'git -C projects/x stash push -m wip' \
    'git -C projects/x stash pop' \
    'git -C projects/x rebase origin/main' \
    'git -C projects/x cherry-pick abc123' \
    'git -C projects/x push origin main' \
    'git -C projects/x clean -fd' \
    'git -C projects/x merge origin/main' \
    'git -C projects/x merge --no-ff origin/main' \
    'git -C projects/x add -A' \
    'git -C projects/x restore .' \
    'git -C projects/x branch -D old' \
    'git -C projects/x branch topic origin/main' \
    'git -C projects/x worktree add /tmp/wt origin/main' \
    'git -C projects/x worktree remove /tmp/wt' \
    'git -C projects/x remote add other https://example.invalid/x.git'; do
    [ "$(policy "$cmd" | cut -f1)" = deny ] || fail "must deny: $cmd => $(policy "$cmd")"
  done
  pass "a state-changing verb aimed at a clone is denied: fetch of a refspec, pull, checkout, switch, reset, commit, stash, rebase, cherry-pick, push, clean, merge without --ff-only, add, restore, branch and worktree and remote changes"
}

test_clone_targets_are_resolved() {
  local cmd
  for cmd in \
    "git -C $HOME_PATH/projects/x reset --hard" \
    'git -C ~/codes/firstmate/projects/x reset --hard' \
    'git -C ./projects/x reset --hard' \
    'git -C projects/x -c core.pager=cat reset --hard' \
    'git -c core.pager=cat -C projects/x reset --hard' \
    'git -C projects -C x reset --hard' \
    'git --git-dir=projects/x/.git reset --hard' \
    'git --git-dir projects/x/.git --work-tree projects/x reset --hard' \
    'P=projects/x; git -C $P reset --hard' \
    "F=$HOME_PATH; git -C \$F/projects/x reset --hard" \
    'git -C "$FM_HOME/projects/x" reset --hard' \
    '(cd projects/x && git reset --hard)' \
    'cd projects/x; git reset --hard' \
    "cd $HOME_PATH/projects/x && git commit -m x" \
    'git -C projects/x status; git -C projects/x reset --hard' \
    'git -C projects/x log | head -3; git -C projects/x push' \
    "bash -c 'git -C projects/x stash'" \
    'if true; then git -C projects/x checkout main; fi' \
    'echo $(git -C projects/x reset --hard)' \
    'timeout 120 git -C projects/x push origin main' \
    'FM_X=1 git -C projects/x push' \
    'env GIT_TERMINAL_PROMPT=0 git -C projects/x push'; do
    [ "$(policy "$cmd" | cut -f1)" = deny ] || fail "must deny: $cmd => $(policy "$cmd")"
  done
  pass "a clone is found through -C, a home path, ~, a variable, --git-dir, a cd in the same subshell, and inside bash -c, if bodies and substitutions"
}

test_other_targets_and_mentions_are_allowed() {
  local cmd
  for cmd in \
    'git reset --hard' \
    'git commit -m x' \
    'git -C /tmp/wt reset --hard' \
    'git -C /home/dathuynh/.treehouse/cfw-modules-67e880/2/cfw-modules commit -m x' \
    'git -C projects reset --hard' \
    'git -C /srv/other/projects/x push' \
    'git -C "$WT" push origin HEAD' \
    '(cd /tmp/wt && git reset --hard)' \
    '(cd projects/x && true); git commit -m x' \
    'echo "git -C projects/x reset --hard"' \
    'grep -n "git -C projects/x push" docs/notes.md' \
    'cat > /tmp/note <<EOF
git -C projects/x reset --hard
EOF' \
    'ls projects/x; gh pr diff 1699 --repo o/r' \
    'gh pr view 1699 --repo o/r --json files'; do
    [ "$(policy "$cmd")" = allow ] || fail "must allow: $cmd => $(policy "$cmd")"
  done
  pass "git aimed at a worker worktree or a path outside the home, and a command that only mentions a clone git change, are allowed"
}

run_check() {  # <dir> <command>: the wrapper in --claude stdin form; sets RC, OUT, ERR
  local dir=$1 cmd=$2
  OUT=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | FM_HOME="$dir" "$dir/bin/fm-clone-git-pretool-check.sh" --claude 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
}

test_hook_logs_only_until_the_switch_is_set() {
  local dir="$TMP_ROOT/hook-log" log
  make_primary "$dir"
  run_check "$dir" "$CG1_CMD"
  [ "$RC" -eq 0 ] || fail "log-only default must allow, got exit $RC: $ERR"
  [ -z "$OUT$ERR" ] || fail "log-only default must be silent: $OUT $ERR"
  log="$dir/state/enforce-clone-git.log"
  [ -f "$log" ] || fail "log-only default wrote no hit log"
  grep -q 'would-deny	git-fetch-refspec	' "$log" || fail "hit log lacks the would-deny line: $(cat "$log")"
  printf '# block after the day of review\nlog\n' > "$dir/config/enforce-clone-git"
  run_check "$dir" "$CG1_CMD"
  [ "$RC" -eq 0 ] || fail "a config of log must still allow"
  pass "CG1: with config/enforce-clone-git absent or log the fetch is allowed and written to state/enforce-clone-git.log"
}

test_hook_denies_in_block_mode() {
  local dir="$TMP_ROOT/hook-block"
  make_primary "$dir"
  printf 'block\n' > "$dir/config/enforce-clone-git"
  run_check "$dir" "$CG1_CMD"
  [ "$RC" -eq 2 ] || fail "block mode must deny the CG1 command, got exit $RC"
  [ -z "$OUT" ] || fail "claude deny must leave stdout empty: $OUT"
  printf '%s' "$ERR" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("gh pr diff") and test("git -C <worker worktree>"))' >/dev/null \
    || fail "deny answer lacks the safe forms: $ERR"
  printf '%s\n' "$ERR" > "$TMP_ROOT/cg1-hook-answer.json"
  run_check "$dir" "$CG2_CMD_A"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "the sanctioned fetch and merge must pass in block mode: $ERR"
  run_check "$dir" "$CG2_CMD_B"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a read of a clone must pass in block mode: $ERR"
  run_check "$dir" 'ls -la'
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "an unrelated command must pass"
  grep -q '	deny	git-fetch-refspec	' "$dir/state/enforce-clone-git.log" || fail "block mode wrote no deny line: $(cat "$dir/state/enforce-clone-git.log")"
  pass "CG1, CG2: in block mode the PR fetch is denied with the safe forms; the sanctioned fetch and merge and a read pass"
}

test_hook_is_inert_in_a_task_worktree_and_fails_open() {
  local base="$TMP_ROOT/inert-base" wt="$TMP_ROOT/inert-wt"
  make_primary "$base"
  fm_git_worktree "$base" "$wt" fm/clone-guard-test
  : > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$wt/config" "$wt/state"
  cp "$base"/bin/* "$wt/bin/"
  printf 'block\n' > "$wt/config/enforce-clone-git"
  run_check "$wt" "$CG1_CMD"
  [ "$RC" -eq 0 ] && [ -z "$ERR" ] || fail "a task worktree must be inert, got exit $RC: $ERR"
  printf 'not json' | FM_HOME="$base" "$base/bin/fm-clone-git-pretool-check.sh" --claude 2>/dev/null \
    || fail "malformed stdin must fail open"
  pass "the hook is inert in a task worktree and fails open on malformed input"
}

test_claude_settings_register_the_clone_guard() {
  local dir="$TMP_ROOT/wiring" cmd payload rc
  make_primary "$dir"
  printf 'block\n' > "$dir/config/enforce-clone-git"
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("fm-clone-git-pretool-check.sh"))' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "PreToolUse Bash has no fm-clone-git-pretool-check.sh entry in .claude/settings.json"
  payload=$(jq -cn --arg c "$CG1_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$payload" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$dir" FM_HOME="$dir" bash -c "$cmd" >/dev/null 2>"$dir/err"
  rc=$?
  [ "$rc" -eq 2 ] || fail "the registered settings command did not deny the CG1 command: $(cat "$dir/err")"
  pass "the command registered in .claude/settings.json runs the guard and denies the CG1 command in block mode"
}

test_cg3_replay_lists_denied_commands_with_session_ids() {
  local dir="$TMP_ROOT/replay" out
  mkdir -p "$dir"
  jq -cn --arg c "$CG1_CMD" '{timestamp:"2026-10-20T01:02:03Z",message:{content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:$c}}]}}' > "$dir/aaaa1111-0000-0000-0000-000000000000.jsonl"
  # The same tool_use repeated in a streamed entry counts once.
  jq -cn --arg c "$CG1_CMD" '{timestamp:"2026-10-20T01:02:03Z",message:{content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:$c}}]}}' >> "$dir/aaaa1111-0000-0000-0000-000000000000.jsonl"
  jq -cn --arg c "$CG2_CMD_A" '{timestamp:"2026-10-21T01:02:03Z",message:{content:[{type:"tool_use",id:"t2",name:"Bash",input:{command:$c}}]}}' >> "$dir/aaaa1111-0000-0000-0000-000000000000.jsonl"
  jq -cn '{timestamp:"2026-10-22T01:02:03Z",message:{content:[{type:"tool_use",id:"t3",name:"Bash",input:{command:"git -C projects/y push origin main"}}]}}' > "$dir/bbbb2222-0000-0000-0000-000000000000.jsonl"
  out=$(node "$POLICY" --home "$HOME_PATH" --replay "$dir")
  printf '%s\n' "$out" | grep -q "^deny	aaaa1111-0000-0000-0000-000000000000	2026-10-20	git-fetch-refspec	" || fail "replay lacks the fetch with its session id: $out"
  printf '%s\n' "$out" | grep -q "^deny	bbbb2222-0000-0000-0000-000000000000	2026-10-22	git-push	" || fail "replay lacks the push with its session id: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^deny')" -eq 2 ] || fail "replay must list exactly two denials: $out"
  printf '%s\n' "$out" | tail -1 | grep -q '3 Bash commands naming git and projects scanned, 2 denied in 2 sessions' || fail "replay summary: $(printf '%s\n' "$out" | tail -1)"
  pass "CG3: the replay lists each denied command with its session id and day, counts a repeated tool_use once, and prints the totals"
}

test_cg1_the_past_pr_fetch_is_denied
test_cg2_the_sanctioned_forms_are_allowed
test_state_changing_verbs_are_denied
test_clone_targets_are_resolved
test_other_targets_and_mentions_are_allowed
test_hook_logs_only_until_the_switch_is_set
test_hook_denies_in_block_mode
test_hook_is_inert_in_a_task_worktree_and_fails_open
test_claude_settings_register_the_clone_guard
test_cg3_replay_lists_denied_commands_with_session_ids

echo "# fm-clone-git-pretool-check.test.sh: all assertions passed"
