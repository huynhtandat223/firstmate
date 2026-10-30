#!/usr/bin/env bash
# shellcheck disable=SC2016 # Pins are literal Markdown with backticks, never expanded.
# Contract tests for the adapted pstack skills `arena` and `swarm`.
#
# The skills are agent-facing prose that only firstmate runs, so their public
# interface is the contract firstmate reads: the phase names, the fan-out and
# judging rules, the fleet mechanisms that replaced the Cursor ones, the
# trigger-index rows that load them, and the provenance of each adaptation.
# They also pin the capability-router rows that route workers to the adapted
# `how` and `why` skills, and the router's statement on adapted skills.
# These tests pin those load-bearing terms and the absence of the Cursor
# mechanisms, without pinning the prose around them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARENA="$ROOT/.agents/skills/arena"
SWARM="$ROOT/.agents/skills/swarm"
INDEX="$ROOT/.agents/skills/agent-skill-trigger-index/SKILL.md"
INVENTORY="$ROOT/docs/documentation-audiences.json"
POLICY="$ROOT/custom-skills/policy/SKILL.md"
UPSTREAM_COMMIT="1ba91fc25c0977741dd0e267849e6234b037ed0a"

# assert_pins <file> <label> <pin...>: every fixed-string pin must appear in <file>.
assert_pins() {
  local file=$1 label=$2 pin
  shift 2
  assert_present "$file" "$label is missing: $file"
  for pin in "$@"; do
    assert_grep "$pin" "$file" "$label no longer holds: $pin"
  done
}

test_arena_keeps_its_phases_and_rules() {
  assert_pins "$ARENA/SKILL.md" "arena skill" \
    "## Phase A: Frame" \
    "## Phase B: Fan out" \
    "## Phase C: Cross-judge" \
    "## Phase D: Pick" \
    "## Phase E: Graft" \
    "## Phase F: Verify" \
    "Write the rubric before fan-out" \
    "The judge is never from the parent firstmate session's model family." \
    'A seat is a worker started by `bin/fm-spawn.sh`' \
    "Read the usage meters before fan-out and record each reading in the backlog note"
  pass "arena keeps its six phases, the rubric, the judge, the seats and the meter read"
}

test_swarm_keeps_its_phases_and_rules() {
  assert_pins "$SWARM/SKILL.md" "swarm skill" \
    "## Phase A: Frame" \
    "## Phase B: Fan out" \
    "## Phase C: Aggregate" \
    "## Phase D: Report" \
    'Reports use `PASS`, `ISSUES` or `BLOCKED` with evidence.' \
    "lists every issue it can prove, not only the first" \
    'relaunch that worker once with `bin/fm-control.sh <id> relaunch`' \
    "After a second miss, record a gap; a gap is not a pass." \
    'verify-cfw --target url:<base>' \
    "Port 5010 is the captain's UI/UX review Storybook; a slice never serves on it or measures against it." \
    'takes its environment lease first, with `bin/fm-lease.sh claim env:<name> --holder <id>`' \
    "Read the usage meters before fan-out and record each reading in the backlog note"
  pass "swarm keeps its four phases, the verdicts, the relaunch-then-gap rule, url:<base>, the lease and the meter read"
}

test_trigger_index_loads_both_skills() {
  assert_pins "$INDEX" "trigger index" \
    "- \`arena\` - load when the captain says arena, or before dispatching a main task's plan, a component API or a page layout that one attempt would lock into the wrong shape; read the usage meters first and record them in the backlog note." \
    "- \`swarm\` - load when the captain says swarm, or before a verify round across two or more pages, a cross-repository audit, or a race on a bug that failed two rounds; read the usage meters first and record them in the backlog note."
  pass "trigger index holds the arena and swarm rows"
}

test_each_adaptation_names_its_upstream_commit() {
  local dir
  for dir in "$ARENA" "$SWARM"; do
    assert_pins "$dir/PROVENANCE.md" "$(basename "$dir") provenance" "$UPSTREAM_COMMIT"
    assert_present "$dir/LICENSE" "$(basename "$dir") has no upstream LICENSE"
  done
  pass "each PROVENANCE.md names upstream commit $UPSTREAM_COMMIT beside its LICENSE"
}

test_no_cursor_mechanism_remains() {
  local pin hits
  for pin in "Task tool" "subagent_type" "pstack-models" 'environment: "cloud"'; do
    hits=$(grep -rniF -- "$pin" "$ARENA" "$SWARM" || true)
    [ -z "$hits" ] || fail "a Cursor mechanism is back in an adapted skill: $pin"$'\n'"$hits"
  done
  pass "no Cursor mechanism string remains in either skill folder"
}

test_inventory_classifies_the_new_documents() {
  if ! python3 - "$INVENTORY" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
registered = {entry.get("path") for entry in data["surfaces"] if entry.get("audience") == "agent-runtime"}
missing = [path for path in (
    ".agents/skills/arena/SKILL.md",
    ".agents/skills/arena/PROVENANCE.md",
    ".agents/skills/swarm/SKILL.md",
    ".agents/skills/swarm/PROVENANCE.md",
) if path not in registered]
if missing:
    raise SystemExit("not registered as agent-runtime: " + ", ".join(missing))
PY
  then
    fail "arena and swarm documents must be registered agent-runtime in the audience inventory"
  fi
  pass "audience inventory classifies the arena and swarm documents as agent-runtime"
}

# Line number of the first line equal to <text>, or empty when absent.
line_equal() {
  grep -n -x -F -- "$1" "$2" | head -1 | cut -d: -f1
}

test_policy_holds_the_adapted_skill_edits() {
  assert_present "$POLICY" "capability router is missing"
  local line
  for line in \
    'A `worker` may also use the verification capability when it verifies expected behavior or claims a task done, and the `how` and `why` capabilities when their trigger is active.' \
    'The vendored bytes under `custom-skills/matt/` are immutable.' \
    'Adapted skills (`how`, `why`, `arena`, `swarm`) are not vendored: each carries a `PROVENANCE.md` naming its upstream commit and what changed.'; do
    [ -n "$(line_equal "$line" "$POLICY")" ] || fail "capability router no longer holds the line: $line"
  done
  pass "capability router holds the worker grant and the adapted-skill statement"
}

test_policy_routes_how_then_why_after_diagnosis() {
  local diagnosis how why
  diagnosis=$(line_equal '| A diagnosis task is opened | `/home/dathuynh/codes/firstmate/custom-skills/matt/engineering/diagnosing-bugs/SKILL.md` |' "$POLICY")
  how=$(line_equal '| A worker must change or judge existing behaviour it has not traced, or a placement or ownership question is open | `/home/dathuynh/.agents/skills/how/SKILL.md` |' "$POLICY")
  why=$(line_equal '| A worker or firstmate is about to change, remove or overrule something whose reason is not in front of it (a regression stays with the diagnosis row) | `/home/dathuynh/.agents/skills/why/SKILL.md` |' "$POLICY")
  [ -n "$diagnosis" ] || fail "capability router lost the diagnosis row"
  [ -n "$how" ] || fail "capability router has no exact how row routed to /home/dathuynh/.agents/skills/how/SKILL.md"
  [ -n "$why" ] || fail "capability router has no exact why row routed to /home/dathuynh/.agents/skills/why/SKILL.md"
  [ "$diagnosis" -lt "$how" ] || fail "the how row no longer comes after the diagnosis row"
  [ "$how" -lt "$why" ] || fail "the why row no longer comes after the how row"
  pass "capability router routes how, then why, after the diagnosis row by absolute path"
}

test_arena_keeps_its_phases_and_rules
test_swarm_keeps_its_phases_and_rules
test_trigger_index_loads_both_skills
test_each_adaptation_names_its_upstream_commit
test_no_cursor_mechanism_remains
test_inventory_classifies_the_new_documents
test_policy_holds_the_adapted_skill_edits
test_policy_routes_how_then_why_after_diagnosis
