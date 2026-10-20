#!/usr/bin/env bash
# tests/fm-spawn-agent-ask-asker.test.sh - every agent this fleet launches names
# itself to agent-ask by its task id, and a Claude primary session names itself
# `firstmate`, so the reader's Waiting for you view tells one asker from another.
#
# The spawn cases drive the real bin/fm-spawn.sh against a fake pane and a real
# isolated git worktree, then EXECUTE the launch command the pane received, with
# the harness binary replaced by a probe that prints the AGENT_ASK_ASKER it was
# started with. The pane carries the primary's own `firstmate` name, because a
# pane can inherit it, so a launch that only forwarded the pane's value fails.
# The primary case runs the real bin/fm-sessionstart-run.sh as Claude's
# SessionStart hook runs it, then sources CLAUDE_ENV_FILE as Claude does before
# each Bash command.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-agent-ask-asker)
INHERITED=firstmate

# make_case <name> <harness> <id>
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1" >/dev/null
  fm_test_spawn_brief "$HOME_DIR" "$3"
  cat > "$FAKEBIN_DIR/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${AGENT_ASK_ASKER-unset}"
SH
  chmod +x "$FAKEBIN_DIR/$2"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The asker the agent starts with: the pane exports replayed in order, then the
# launch command, in a pane that already holds the inherited name.
# With --launch-only the pane exports are skipped, as for a pane whose exports
# never landed.
launched_asker() {
  local preamble=
  [ "${1-}" = --launch-only ] || preamble=$(grep -E '^(export|unset) ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane AGENT_ASK_ASKER="$INHERITED" \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

# The asker a later command in the pane shell sees, from the pane exports alone.
pane_asker() {
  env -i PATH="$PATH" AGENT_ASK_ASKER="$INHERITED" /bin/sh -c "$(grep -E '^(export|unset) ' "$PANE_LOG")
printf '%s\n' \"\${AGENT_ASK_ASKER-unset}\""
}

test_ship_and_scout() {
  local kind setting id flag out status
  for kind in ship scout; do
    for setting in absent enabled; do
      id="$kind-asker-$setting"
      make_case "$id" codex "$id"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      flag=(--mode no-mistakes --yolo off)
      [ "$kind" = ship ] || flag=(--scout)
      out=$(run_case_spawn "$id" "$PROJ_DIR" "${flag[@]}")
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      assert_equals "$id" "$(launched_asker)" "$kind, allowlist $setting: the agent must start named by its task id"
      assert_equals "$id" "$(launched_asker --launch-only)" "$kind, allowlist $setting: the launch command alone must set the name"
      assert_equals "$id" "$(pane_asker)" "$kind, allowlist $setting: later pane commands must carry the name"
    done
  done
  pass "ship and scout agents start named by their task id, with or without the launch allowlist"
}

test_secondmate() {
  local sm out status
  make_case secondmate codex sm-asker
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-asker\n' > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-asker "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  assert_equals sm-asker "$(launched_asker)" "a secondmate must start named by its id"
  pass "a secondmate starts named by its id"
}

# agent-ask refuses an asker that does not start with a letter or digit, so such
# an id must clear the inherited name rather than pass it on or break the ask.
test_id_agent_ask_refuses() {
  local out status
  make_case odd-id codex _odd-id
  out=$(run_case_spawn _odd-id "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn of an id agent-ask refuses should still succeed: $out"
  assert_equals unset "$(launched_asker)" "an id agent-ask refuses must leave the agent unnamed, not inherit firstmate"
  pass "an id agent-ask would refuse leaves the agent unnamed instead of inheriting the primary's name"
}

# The real hook in a plain primary checkout, fed a Claude SessionStart payload.
# The digest itself is replaced by a stub: only the asker export is under test.
primary_env_file() {  # <ambient-asker or empty>
  local primary="$TMP_ROOT/primary" envfile="$TMP_ROOT/primary/claude-env"
  rm -rf "$primary"
  mkdir -p "$primary/bin" "$primary/state"
  cp "$ROOT"/bin/*.sh "$primary/bin/"
  printf '#!/bin/sh\nexit 0\n' > "$primary/bin/fm-session-start.sh"
  chmod +x "$primary/bin/fm-session-start.sh"
  printf '# Firstmate\n' > "$primary/AGENTS.md"
  git -C "$primary" init -q
  : > "$envfile"
  printf '{"hook_event_name":"SessionStart","source":"startup"}' |
    env -u FM_TASK_ID -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u AGENT_ASK_ASKER \
      ${1:+AGENT_ASK_ASKER=$1} CLAUDE_ENV_FILE="$envfile" "$primary/bin/fm-sessionstart-run.sh" >/dev/null
  env -i PATH="$PATH" ${1:+AGENT_ASK_ASKER=$1} /bin/sh -c ". '$envfile'; printf '%s\n' \"\${AGENT_ASK_ASKER-unset}\""
}

test_claude_primary_session() {
  assert_equals firstmate "$(primary_env_file '')" "a Claude primary session's Bash commands must carry the firstmate name"
  assert_equals dms "$(primary_env_file dms)" "a session Firstmate launched must keep its own name"
  pass "a Claude primary session names itself firstmate and a launched session keeps its own name"
}

test_ship_and_scout
test_secondmate
test_id_agent_ask_refuses
test_claude_primary_session
