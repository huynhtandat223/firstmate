#!/usr/bin/env bash
# Focused role manifest tests for fm-brief's Available skills output.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-role-skills)

test_role_manifest_selects_planner_and_worker_lists() {
  local home planner worker
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" planner app --scout --role planner >/dev/null || fail "planner brief failed"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" worker app --mode no-mistakes --role worker >/dev/null || fail "worker brief failed"
  planner="$home/data/planner/brief.md"
  worker="$home/data/worker/brief.md"
  assert_grep "$ROOT/.agents/custom-skills/planner/SKILL.md" "$planner" "planner list omitted custom planner skill"
  assert_grep "$ROOT/.agents/skills/to-questionnaire/SKILL.md" "$planner" "planner list omitted questionnaire skill"
  assert_grep "$HOME/.agents/skills/handoff/SKILL.md" "$planner" "planner list omitted global handoff"
  assert_grep "$ROOT/.agents/skills/tdd/SKILL.md" "$worker" "worker list omitted tdd"
  assert_no_grep 'to-questionnaire' "$worker" "worker list indiscriminately includes planner skill"
  assert_no_grep '{AVAILABLE_SKILLS}' "$planner" "planner list left placeholder"
  pass "role manifest renders selected Available skills lists"
}

test_unknown_role_retains_placeholder_for_spawn_rejection() {
  local home brief
  home="$TMP_ROOT/unknown"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" unknown app --scout >/dev/null || fail "unselected-role scaffold failed"
  brief="$home/data/unknown/brief.md"
  assert_grep 'AVAILABLE_SKILLS' "$brief" "unselected role should remain incomplete"
  pass "unknown role leaves Available skills unresolved"
}

test_role_manifest_selects_planner_and_worker_lists
test_unknown_role_retains_placeholder_for_spawn_rejection
