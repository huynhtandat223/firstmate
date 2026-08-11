#!/usr/bin/env bash
# Contract tests for the paired-review navigator's writing-for-agents pointer.
#
# The navigator procedure must carry a one-line reminder that points the driver
# at the single authoritative writing-process owner before agent-facing edits.
# These tests protect the trigger and the pointer without pinning reminder
# prose: the stable reference identity is the skill path, so only a retarget or
# removal of the pointer fails, never a harmless reword.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAVIGATOR="$ROOT/custom-skills/paired-review/navigator/SKILL.md"
WRITING_FOR_AGENTS="$ROOT/custom-skills/matt/productivity/writing-for-agents/SKILL.md"
WRITING_POINTER="custom-skills/matt/productivity/writing-for-agents/SKILL.md"
NAVIGATOR_POINTER="custom-skills/paired-review/navigator/SKILL.md"
INVENTORY="$ROOT/docs/documentation-audiences.json"

test_navigator_carries_the_writing_pointer() {
  assert_present "$NAVIGATOR" "paired-review navigator skill is missing"
  assert_grep "$WRITING_POINTER" "$NAVIGATOR" \
    "navigator procedure no longer points the driver at the writing-for-agents owner"
  pass "navigator procedure points the driver at the writing-for-agents skill"
}

test_pointer_target_is_real_and_tracked() {
  assert_present "$WRITING_FOR_AGENTS" "writing-for-agents skill is missing at the pointer target"
  git -C "$ROOT" ls-files --error-unmatch "$WRITING_POINTER" >/dev/null 2>&1 \
    || fail "writing-for-agents skill is not git-tracked"
  pass "pointer target exists and is git-tracked"
}

test_pointer_ownership_is_one_directional() {
  assert_no_grep "$NAVIGATOR_POINTER" "$WRITING_FOR_AGENTS" \
    "writing-for-agents must not point back at the navigator (ownership inversion)"
  pass "writing-for-agents stays the sole owner without a reverse pointer"
}

test_both_surfaces_are_registered_agent_runtime() {
  if ! python3 - "$INVENTORY" "$WRITING_POINTER" "$NAVIGATOR_POINTER" <<'PY'
import json
import sys

inventory_path, writing_path, navigator_path = sys.argv[1:4]
data = json.load(open(inventory_path, encoding="utf-8"))
surfaces = data["surfaces"]
for path in (writing_path, navigator_path):
    if not any(entry.get("path") == path and entry.get("audience") == "agent-runtime"
               for entry in surfaces):
        raise SystemExit("not registered as an agent-runtime surface: " + path)
PY
  then
    fail "navigator and writing-for-agents must both be registered agent-runtime surfaces"
  fi
  pass "both surfaces are registered agent-runtime in the audience inventory"
}

test_navigator_carries_the_writing_pointer
test_pointer_target_is_real_and_tracked
test_pointer_ownership_is_one_directional
test_both_surfaces_are_registered_agent_runtime
