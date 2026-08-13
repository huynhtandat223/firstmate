#!/usr/bin/env bash
# Contract checks for the /orchestrator policy surface and its brief writer.
#
# The runtime guarantees are covered by tests/fm-temporary-supervisor.test.sh.
# What this file pins is the half a script cannot enforce: that the skill the
# captain reaches still routes to a TEMPORARY supervisor with a leased home,
# never back to a persistent secondmate or to a scout that cannot supervise
# children, that firstmate's part stops at intake while task decomposition and
# per-child routing stay with the supervisor, and that the brief it scaffolds
# states the boundaries the runtime will actually enforce.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT_DIR/custom-skills/orchestrator/SKILL.md"
PROGRAMME="$ROOT_DIR/custom-skills/orchestrator/PROGRAMME.md"
PROCEDURE="$ROOT_DIR/custom-skills/program-orchestration/SKILL.md"
POLICY="$ROOT_DIR/custom-skills/policy/SKILL.md"
BRIEF_WRITER="$ROOT_DIR/custom-skills/orchestrator/fm-supervisor-brief.sh"

test_skill_opens_a_temporary_supervisor() {
  assert_present "$SKILL" "the orchestrator skill is missing"
  assert_grep '--supervisor' "$SKILL" "the skill does not name the supervisor spawn"
  assert_grep 'temporary firstmate session' "$SKILL" "the skill does not describe a temporary session"
  assert_grep 'leased' "$SKILL" "the skill does not describe the home as leased"
  assert_no_grep '--scout' "$SKILL" "the skill still opens the supervisor as a scout"
  assert_no_grep 'persistent secondmate' "$SKILL" "the skill still describes a persistent secondmate"
  assert_grep 'byte-identical' "$SKILL" "the skill does not require data/secondmates.md to stay unchanged"
  pass "orchestrator: the skill opens one temporary supervisor in a leased home"
}

test_skill_covers_relaunch_and_cleanup() {
  assert_grep 'Relaunch a stopped supervisor' "$SKILL" "the skill has no relaunch step"
  assert_grep 'One programme, one supervisor, one home' "$SKILL" "the skill does not state the no-duplicate invariant"
  assert_grep 'reconciles the workers already recorded there' "$SKILL" "the skill does not require child reconciliation on relaunch"
  assert_grep 'Cleanup names anything still outstanding' "$SKILL" "the skill does not describe the cleanup refusals"
  pass "orchestrator: the skill covers relaunch into the same home and the cleanup refusals"
}

test_skill_gives_child_routing_to_the_supervisor() {
  local bad
  assert_no_grep '{TASK}' "$SKILL" "the skill still carries the scaffold's task placeholder"
  assert_no_grep '{SCOPE}' "$SKILL" "the skill still carries the scaffold's scope placeholder"

  assert_grep 'The supervisor owns the programme' "$SKILL" \
    "the skill does not state who owns the programme after launch"
  assert_grep 'It decomposes the authorized work into task cards' "$SKILL" \
    "the skill does not give task decomposition to the supervisor"
  assert_grep "It resolves each child worker's concrete harness, model, and effort" "$SKILL" \
    "the skill does not give per-child profile resolution to the supervisor"
  assert_grep "records that routing on the child's card" "$SKILL" \
    "the skill does not make the supervisor record the child's routing"

  # Firstmate resolves the SUPERVISOR's own profile and nothing below it, so no
  # line may name firstmate, a child or worker, and a profile axis together.
  bad=$(grep -n -i -E 'firstmate' "$SKILL" \
    | grep -i -E 'worker|child' \
    | grep -i -E 'harness|model|effort|profile|routing' || true)
  [ -z "$bad" ] \
    || fail "the skill reads as firstmate owning a child worker's profile:"$'\n'"$bad"

  pass "orchestrator: the skill gives task decomposition and child routing to the supervisor"
}

test_skill_names_an_explicit_profile_on_every_launch() {
  local launches bad
  launches=$(grep -n -E 'fm-spawn\.sh' "$SKILL" | grep -v -e '--help' || true)
  [ -n "$launches" ] || fail "the skill shows no supervisor launch command"
  bad=$(printf '%s\n' "$launches" | awk '!/--harness/ || !/--model/ || !/--effort/')
  [ -z "$bad" ] \
    || fail "a launch command in the skill omits an explicit profile flag:"$'\n'"$bad"

  # shellcheck disable=SC2016 # Fixed-string match; the backticks are the skill's markdown.
  assert_grep 'Every launch in this programme names its profile out loud with `--harness`, `--model`, and `--effort`' \
    "$SKILL" "the skill does not require an explicit profile on every launch"

  pass "orchestrator: every supervisor and worker launch names harness, model, and effort"
}

test_procedure_is_not_a_secondmate_procedure() {
  assert_present "$PROCEDURE" "the programme procedure is missing"
  assert_grep 'It is not a second mate' "$PROCEDURE" "the procedure does not disown the secondmate lifecycle"
  assert_no_grep 'secondmate-provisioning' "$PROCEDURE" "the procedure still routes to secondmate provisioning"
  assert_grep 'custody' "$PROCEDURE" "the procedure lost its one-ticket custody rule"
  pass "program-orchestration: the procedure no longer routes through secondmate provisioning"
}

test_programme_requires_reading_the_inventory_after_a_restart() {
  assert_present "$PROGRAMME" "the programme procedure is missing"
  assert_grep 'After any relaunch, read the recorded worker inventory as the source before dispatching' \
    "$PROGRAMME" "the programme procedure does not require reading the inventory first"
  assert_grep 'your recollection of the inventory is a report about it' \
    "$PROGRAMME" "the programme procedure lost the restart judgment behind that rule"
  pass "orchestrator: the programme procedure requires reading the worker inventory after a restart"
}

test_policy_routes_the_captain_to_the_skill() {
  assert_grep '/orchestrator' "$POLICY" "the policy does not route /orchestrator"
  assert_grep 'custom-skills/orchestrator/SKILL.md' "$POLICY" "the policy names no orchestrator capability"
  assert_grep 'role=supervisor' "$POLICY" "the policy does not recognise the supervisor role"
  pass "policy: /orchestrator and role=supervisor both route to the orchestrator capability"
}

test_brief_states_the_boundaries_the_runtime_enforces() {
  local tmp brief
  tmp=$(fm_test_tmproot fm-orchestrator-policy)
  mkdir -p "$tmp/home/data" "$tmp/home/state" "$tmp/home/projects"
  FM_HOME="$tmp/home" "$BRIEF_WRITER" prog-contract-a1 >/dev/null \
    || fail "the brief writer failed"
  brief="$tmp/home/data/prog-contract-a1/brief.md"
  assert_present "$brief" "the brief writer wrote no brief"
  assert_grep '{TASK}' "$brief" "the brief has no task placeholder"
  assert_grep '{SCOPE}' "$brief" "the brief has no scope placeholder"
  assert_grep 'READ-ONLY allocation sources' "$brief" "the brief does not make the parent clones read-only"
  assert_grep 'You have no project clones of your own' "$brief" "the brief does not forbid cloning into the home"
  assert_grep 'never address the captain' "$brief" "the brief does not state the captain conversation boundary"
  assert_grep "$tmp/home/data/prog-contract-a1/report.md" "$brief" "the brief does not name the parent-home report"
  assert_grep 'reconcile the workers already recorded' "$brief" "the brief does not require relaunch reconciliation"
  pass "orchestrator: the scaffolded brief states the boundaries the runtime enforces"
}

test_brief_refuses_to_overwrite() {
  local tmp out status
  tmp=$(fm_test_tmproot fm-orchestrator-policy-overwrite)
  mkdir -p "$tmp/home/data" "$tmp/home/state" "$tmp/home/projects"
  FM_HOME="$tmp/home" "$BRIEF_WRITER" prog-overwrite-b2 >/dev/null || fail "the first scaffold failed"
  out=$(FM_HOME="$tmp/home" "$BRIEF_WRITER" prog-overwrite-b2 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the brief writer overwrote an existing brief"
  assert_contains "$out" "already exists" "unexpected overwrite refusal text"
  pass "orchestrator: the brief writer refuses to overwrite an existing brief"
}

test_skill_opens_a_temporary_supervisor
test_skill_covers_relaunch_and_cleanup
test_skill_gives_child_routing_to_the_supervisor
test_skill_names_an_explicit_profile_on_every_launch
test_procedure_is_not_a_secondmate_procedure
test_programme_requires_reading_the_inventory_after_a_restart
test_policy_routes_the_captain_to_the_skill
test_brief_states_the_boundaries_the_runtime_enforces
test_brief_refuses_to_overwrite

echo "# all fm-orchestrator-policy tests passed"
