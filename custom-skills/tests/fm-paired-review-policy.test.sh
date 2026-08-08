#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY="$ROOT_DIR/custom-skills/policy/SKILL.md"
PAIRED="$ROOT_DIR/custom-skills/paired-review/SKILL.md"
OLD_OWNER="$ROOT_DIR/.agents/skills/paired-review/SKILL.md"
CLAUDE_COMPAT="$ROOT_DIR/.claude/skills/paired-review/SKILL.md"

# The custom owner exists at the custom path.
assert_present "$PAIRED" "custom paired-review owner is missing"

# The policy carries both paired role routes.
assert_grep 'A paired brief carries `role=driver`' "$POLICY" "paired-driver route is missing"
assert_grep 'A paired brief carries `role=navigator`' "$POLICY" "paired-navigator route is missing"

# First-match order: each paired row precedes its generic fallback row.
DRIVER_ROW=$(grep -n -F 'A paired brief carries `role=driver`' "$POLICY" | head -1 | cut -d: -f1)
IMPLEMENT_ROW=$(grep -n -F 'An implementation worker is asked to implement' "$POLICY" | head -1 | cut -d: -f1)
NAV_ROW=$(grep -n -F 'A paired brief carries `role=navigator`' "$POLICY" | head -1 | cut -d: -f1)
REVIEW_ROW=$(grep -n -F 'A review or navigator task is opened' "$POLICY" | head -1 | cut -d: -f1)
[ -n "$DRIVER_ROW" ] && [ -n "$IMPLEMENT_ROW" ] && [ "$DRIVER_ROW" -lt "$IMPLEMENT_ROW" ] || fail "paired-driver route does not precede the generic implement route"
[ -n "$NAV_ROW" ] && [ -n "$REVIEW_ROW" ] && [ "$NAV_ROW" -lt "$REVIEW_ROW" ] || fail "paired-navigator route does not precede the generic code-review route"

# Path resolution: the policy resolves the custom paired-review owner, and the
# custom owner points back to the policy router instead of the stripped scaffold.
assert_grep 'custom-skills/paired-review/SKILL.md' "$POLICY" "policy does not resolve the custom paired-review owner path"
assert_grep 'custom-skills/policy/SKILL.md' "$PAIRED" "custom owner lacks the policy route pointer"
assert_no_grep 'bin/fm-brief.sh --role' "$PAIRED" "custom owner still references the stripped scaffold role flag"

# The old owner is gone everywhere it could resolve, including through the
# .claude/skills compatibility symlink, whose target is .agents/skills.
assert_absent "$OLD_OWNER" "old .agents/skills paired-review owner still resolves"
assert_absent "$CLAUDE_COMPAT" "stale paired-review owner still resolves through the .claude/skills symlink"

pass "custom paired-review owner, policy route, and path resolution contract"
