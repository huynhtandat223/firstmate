#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY="$ROOT_DIR/custom-skills/policy/SKILL.md"
LAUNCHER="$ROOT_DIR/custom-skills/planner/SKILL.md"
AGENTS="$ROOT_DIR/AGENTS.md"

assert_present "$POLICY" "policy is missing"
assert_present "$LAUNCHER" "launcher is missing"
assert_grep 'role=<name>' "$POLICY" "role detection is missing"
assert_grep 'role-allowed capability set' "$POLICY" "role capability boundary is missing"
assert_grep 'The policy is read once per role session' "$POLICY" "policy is not read once"
assert_grep 'Re-pitch before questions' "$POLICY" "re-pitch step is missing"
assert_grep 'confirm or correct' "$POLICY" "captain framing confirmation is missing"
assert_grep 'frontier' "$POLICY" "frontier routing is missing"
assert_grep 'explicit captain instruction' "$POLICY" "explicit crystallization gate is missing"
assert_grep 'to-spec/SKILL.md' "$POLICY" "to-spec routing is missing"
assert_grep 'to-tickets/SKILL.md' "$POLICY" "to-tickets routing is missing"
assert_grep 'remain available until the captain explicitly returns or closes' "$POLICY" "publish-stays-open is missing"
assert_grep 'best-practice direction by default' "$POLICY" "best-practice default is missing"
assert_no_grep 'simplest-workable alternative' "$POLICY" "unsolicited simplest alternative is present in policy"
assert_no_grep 'workaround' "$POLICY" "unsolicited workaround is present in policy"
assert_no_grep 'degraded path' "$POLICY" "unsolicited degraded path is present in policy"
assert_no_grep 'fallback' "$POLICY" "unsolicited fallback is present in policy"
assert_grep 'role=planner' "$LAUNCHER" "planner role disclosure is missing"
assert_grep 'custom-skills/policy/SKILL.md' "$LAUNCHER" "worker policy pointer is missing"
assert_grep 'reads policy, not this launcher' "$LAUNCHER" "worker launcher boundary is missing"
assert_grep 'Keep the planner session open' "$LAUNCHER" "launcher session-open boundary is missing"
assert_grep 'custom-skills/policy/SKILL.md' "$AGENTS" "AGENTS policy pointer is missing"

# Instruction-only planner behavior has no executable conversation seam.
# This contract test pins the public Markdown interface; captain-driven runtime
# behavior is manually verified outside this suite.
pass "custom planner policy and launcher contract"
