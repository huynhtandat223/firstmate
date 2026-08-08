#!/usr/bin/env bash
# Behavior tests for fm-spawn's Available skills admission gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-available-skills)

run_case() {
  local body=$1 out status home project id
  id="skills-gate-$(date +%s%N)"
  home="$TMP_ROOT/home-$id"
  project="$TMP_ROOT/project"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$project"
  printf '%s\n' "$body" > "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_SPAWN_NO_GUARD=1 "$SPAWN" "$id" "$project" codex --backend tmux --mode no-mistakes --yolo off 2>&1)
  status=$?
  printf '%s\t%s\n' "$status" "$out"
}

expect_refusal() {
  local body=$1 expected=$2 result status out
  result=$(run_case "$body")
  status=${result%%$'\t'*}
  out=${result#*$'\t'}
  [ "$status" -ne 0 ] || fail "spawn unexpectedly accepted malformed skill section"
  printf '%s\n' "$out" | grep -F "$expected" >/dev/null || fail "missing refusal '$expected': $out"
}

test_refuses_malformed_skill_sections() {
  expect_refusal '# Task' 'has no Available skills section'
  expect_refusal $'## Available skills\n\n{AVAILABLE_SKILLS}' 'has unresolved Available skills'
  expect_refusal $'## Available skills\n\n- `/does/not/exist/SKILL.md`' 'listed skill does not exist'
  mkdir -p "$TMP_ROOT/escape"
  : > "$TMP_ROOT/escape/SKILL.md"
  expect_refusal "## Available skills

- \`$TMP_ROOT/escape/SKILL.md\`" 'listed skill escapes Firstmate home'
  pass "spawn rejects absent, incomplete, missing, and escaping Available skills"
}

test_valid_list_reaches_existing_spawn_validation() {
  local result status out
  result=$(run_case "## Available skills

- \`$ROOT/.agents/skills/tdd/SKILL.md\`
- \`$HOME/.agents/skills/handoff/SKILL.md\`

Delivery contract: mode=no-mistakes")
  status=${result%%$'\t'*}
  out=${result#*$'\t'}
  [ "$status" -ne 0 ] || fail "fixture should stop later because it is not a worktree"
  printf '%s\n' "$out" | grep -F 'worktree' >/dev/null || fail "valid list did not pass Available skills validation: $out"
  pass "valid role-specific list reaches ordinary spawn validation"
}

test_refuses_malformed_skill_sections
test_valid_list_reaches_existing_spawn_validation
