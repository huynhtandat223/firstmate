#!/usr/bin/env bash
# Contract tests for the classical-testing verification skill and its route.
#
# The skill is agent-facing prose, so its public interface is the contract an
# implementation worker reads: the project-owned TESTING_DATA.md seam, the
# strongest-first ladder, the one-step degradation record, and the
# verification-pending outcome. These tests pin those load-bearing terms, the
# router row that reaches the skill, and the audience classification, without
# pinning the prose around them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_REL="custom-skills/classical-testing/SKILL.md"
SKILL="$ROOT/$SKILL_REL"
POLICY="$ROOT/custom-skills/policy/SKILL.md"
INVENTORY="$ROOT/docs/documentation-audiences.json"

# Line number of the first fixed-string match, or empty when absent.
line_of() {
  grep -n -F -- "$1" "$2" | head -1 | cut -d: -f1
}

test_skill_reads_the_project_testing_contract() {
  assert_present "$SKILL" "classical-testing skill is missing"
  assert_grep "TESTING_DATA.md" "$SKILL" \
    "skill no longer names the project testing contract"
  assert_grep "project's root" "$SKILL" \
    "skill no longer discovers the project contract at the project root"
  assert_grep 'before choosing or running verification' "$SKILL" \
    "skill no longer reads the project contract before verification starts"
  assert_grep 'A missing file grants no new authority' "$SKILL" \
    "skill no longer bounds authority when the project contract is absent"
  pass "skill reads the project-root TESTING_DATA.md before verification"
}

test_declared_assets_stay_authorized_testing_assets() {
  assert_grep 'real infrastructure and persisted data' "$SKILL" \
    "skill no longer treats declared real infrastructure as a testing asset"
  assert_grep 'production-like appearance is not a blocker' "$SKILL" \
    "skill allows a downgrade because an authorized asset looks production-like"
  pass "declared assets stay authorized testing assets"
}

test_ladder_is_strongest_first_and_degrades_one_step() {
  local assembled composition graph component
  assembled=$(line_of '**Assembled system**' "$SKILL")
  composition=$(line_of '**Real service composition**' "$SKILL")
  graph=$(line_of '**Real first-party component graph**' "$SKILL")
  component=$(line_of '**Public component boundary**' "$SKILL")
  [ -n "$assembled" ] || fail "ladder is missing the assembled-system level"
  [ -n "$composition" ] || fail "ladder is missing the real service composition level"
  [ -n "$graph" ] || fail "ladder is missing the first-party component graph level"
  [ -n "$component" ] || fail "ladder is missing the public component boundary level"
  [ "$assembled" -lt "$composition" ] || fail "ladder no longer starts at the assembled system"
  [ "$composition" -lt "$graph" ] || fail "ladder no longer ranks service composition above the component graph"
  [ "$graph" -lt "$component" ] || fail "ladder no longer ranks the component graph above a component boundary"
  assert_grep 'Enter at the strongest level' "$SKILL" \
    "skill no longer enters the ladder at the strongest suitable level"
  assert_grep 'Lower the level one step at a time' "$SKILL" \
    "skill no longer restricts degradation to one step"
  pass "ladder is strongest-first and degrades one step at a time"
}

test_degradation_requires_blocker_evidence_and_residual_risk() {
  assert_grep 'only after observing a concrete blocker' "$SKILL" \
    "degradation no longer requires an observed blocker"
  assert_grep 'blocker evidence' "$SKILL" \
    "downgrade record no longer names blocker evidence"
  assert_grep 'the claims it does not prove' "$SKILL" \
    "downgrade record no longer names the claims left unproven"
  assert_grep 'residual risk' "$SKILL" \
    "downgrade record no longer names residual risk"
  pass "each downgrade records blocker evidence, missing claims, and residual risk"
}

test_mocks_are_excluded_from_the_ladder() {
  assert_grep 'Mocks, stubs, and fakes are not levels of this ladder' "$SKILL" \
    "mocks, stubs, and fakes are no longer excluded from the fallback ladder"
  assert_grep 'they never carry the practical-behavior claim' "$SKILL" \
    "other automated checks may now carry the practical-behavior claim"
  pass "mocks, stubs, and fakes stay off the verification ladder"
}

test_unproven_behavior_stays_verification_pending() {
  assert_grep 'verification pending' "$SKILL" \
    "skill no longer reports verification pending"
  assert_grep 'treat the task as not done' "$SKILL" \
    "unproven expected behavior may now be claimed done"
  pass "unproven expected behavior stays verification pending"
}

test_router_trigger_reaches_the_skill() {
  assert_present "$POLICY" "capability router is missing"
  local row trigger target
  row=$(grep -F -- "$SKILL_REL" "$POLICY" | head -1)
  [ -n "$row" ] || fail "capability router has no route to $SKILL_REL"
  case "$row" in
    '|'*'|'*'|') : ;;
    *) fail "the classical-testing route is not a router trigger row: $row" ;;
  esac
  trigger=$(printf '%s\n' "$row" | cut -d'|' -f2)
  target=$(printf '%s\n' "$row" | cut -d'|' -f3 | tr -d ' `')
  case "$trigger" in
    *[Vv]erif*) : ;;
    *) fail "router trigger does not name verification: $trigger" ;;
  esac
  assert_contains "$trigger" "completion claim" "router trigger does not name the completion claim"
  case "$target" in
    *"$SKILL_REL") : ;;
    *) fail "router route points at $target instead of $SKILL_REL" ;;
  esac
  git -C "$ROOT" ls-files --error-unmatch "$SKILL_REL" >/dev/null 2>&1 \
    || fail "classical-testing skill is not git-tracked at the routed path"
  assert_grep 'may also use the verification capability' "$POLICY" \
    "no implementing role may reach the verification capability"
  assert_no_grep 'TESTING_DATA' "$POLICY" \
    "router duplicates the project-contract procedure instead of pointing at the skill"
  assert_no_grep 'verification pending' "$POLICY" \
    "router duplicates the verification-pending outcome instead of pointing at the skill"
  pass "router trigger reaches the tracked classical-testing skill without duplicating it"
}

test_inventory_classifies_the_skill_as_agent_runtime() {
  if ! python3 - "$INVENTORY" "$SKILL_REL" <<'PY'
import json
import sys

inventory_path, skill_path = sys.argv[1:3]
data = json.load(open(inventory_path, encoding="utf-8"))
if not any(entry.get("path") == skill_path and entry.get("audience") == "agent-runtime"
           for entry in data["surfaces"]):
    raise SystemExit("not registered as an agent-runtime surface: " + skill_path)
PY
  then
    fail "classical-testing skill must be registered agent-runtime in the audience inventory"
  fi
  pass "audience inventory classifies the skill as agent-runtime"
}

test_skill_reads_the_project_testing_contract
test_declared_assets_stay_authorized_testing_assets
test_ladder_is_strongest_first_and_degrades_one_step
test_degradation_requires_blocker_evidence_and_residual_risk
test_mocks_are_excluded_from_the_ladder
test_unproven_behavior_stays_verification_pending
test_router_trigger_reaches_the_skill
test_inventory_classifies_the_skill_as_agent_runtime
