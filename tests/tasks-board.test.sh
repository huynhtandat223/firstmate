#!/usr/bin/env bash
# Behavior tests for the tracked captain work board contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_tasks_board_is_tracked_and_seeded() {
  local board="$ROOT/tasks.mdx"

  [ -f "$board" ] || fail "tasks.mdx is missing"
  assert_grep '# Captain' "$board" "tasks board lacks a captain-facing title"
  assert_grep '## Legend' "$board" "tasks board lacks a legend"
  assert_grep 'PS-Agent-Kit - execution observability' "$board" "tasks board lacks execution-observability work"
  assert_grep 'https://github.com/huynhtandat223/plannotator/pull/8' "$board" "tasks board lacks the Plannotator review link"
  assert_grep 'Plannotator - last amendment' "$board" "tasks board lacks the amendment work"
  assert_grep 'PS-Agent-Kit - v8 onboarding' "$board" "tasks board lacks the held onboarding work"
  pass "tasks board is tracked and seeded from active work"
}

test_tasks_board_preserves_captain_response_contract() {
  local board="$ROOT/tasks.mdx"

  assert_grep '**Captain response:**' "$board" "tasks board lacks dedicated captain-response fields"
  assert_grep '## Update contract' "$board" "tasks board lacks its update contract"
  assert_grep 'preserve any captain-authored response' "$board" "tasks board does not preserve captain responses"
  assert_grep 'Routine progress and automatic retries update neither this board nor captain-facing chat' "$board" "tasks board does not suppress routine status messages"
  pass "tasks board owns the captain-response and update contract"
}

test_guidance_references_tasks_board_contract() {
  assert_grep '`tasks.mdx` is the tracked, captain-editable board and owns its update contract' "$ROOT/AGENTS.md" "AGENTS.md does not route updates to the tasks board"
  assert_grep '`tasks.mdx` is the tracked, captain-editable board for current project work' "$ROOT/CONTRIBUTING.md" "CONTRIBUTING.md does not document the tasks board"
  pass "operating guidance references the tasks board contract"
}

test_tasks_board_is_tracked_and_seeded
test_tasks_board_preserves_captain_response_contract
test_guidance_references_tasks_board_contract
