#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY="$ROOT_DIR/custom-skills/policy/SKILL.md"
PARENT="$ROOT_DIR/custom-skills/paired-review/SKILL.md"
DRIVER="$ROOT_DIR/custom-skills/paired-review/driver/SKILL.md"
NAVIGATOR="$ROOT_DIR/custom-skills/paired-review/navigator/SKILL.md"
HELPER="$ROOT_DIR/custom-skills/paired-review/fm-pair-compose.sh"

assert_present "$PARENT" "paired-review parent is missing"
assert_present "$DRIVER" "paired-review driver skill is missing"
assert_present "$NAVIGATOR" "paired-review navigator skill is missing"
assert_present "$HELPER" "paired-review composition helper is missing"

assert_grep 'A paired brief carries `role=driver`' "$POLICY" "paired-driver route is missing"
assert_grep 'A paired brief carries `role=navigator`' "$POLICY" "paired-navigator route is missing"
assert_grep 'custom-skills/paired-review/driver/SKILL.md' "$POLICY" "driver route misses driver skill"
assert_grep 'custom-skills/paired-review/navigator/SKILL.md' "$POLICY" "navigator route misses navigator skill"
assert_no_grep 'custom-skills/paired-review/SKILL.md`, then' "$POLICY" "a worker route still reads the parent"

DRIVER_ROW=$(grep -n -F 'A paired brief carries `role=driver`' "$POLICY" | head -1 | cut -d: -f1)
IMPLEMENT_ROW=$(grep -n -F 'An implementation worker is asked to implement' "$POLICY" | head -1 | cut -d: -f1)
NAV_ROW=$(grep -n -F 'A paired brief carries `role=navigator`' "$POLICY" | head -1 | cut -d: -f1)
REVIEW_ROW=$(grep -n -F 'A review or navigator task is opened' "$POLICY" | head -1 | cut -d: -f1)
[ "$DRIVER_ROW" -lt "$IMPLEMENT_ROW" ] || fail "paired-driver route follows generic implementation"
[ "$NAV_ROW" -lt "$REVIEW_ROW" ] || fail "paired-navigator route follows generic review"

assert_grep 'fm-pair-compose.sh send' "$PARENT" "parent does not own the verified live-signal method"
assert_grep 'fm-pair-compose.sh send' "$DRIVER" "driver instructions do not name the verified send method"
assert_grep 'fm-pair-compose.sh send' "$NAVIGATOR" "navigator instructions do not name the verified send method"
assert_no_grep 'agent send' "$DRIVER" "driver instructions still send via raw Herdr"
assert_no_grep 'agent send' "$NAVIGATOR" "navigator instructions still send via raw Herdr"
assert_no_grep 'pane send-text' "$DRIVER" "driver instructions still send via raw pane text"
assert_no_grep 'pane send-text' "$NAVIGATOR" "navigator instructions still send via raw pane text"
assert_no_grep 'agent target' "$DRIVER" "driver exposes a Herdr target as a send destination"
assert_no_grep 'agent target' "$NAVIGATOR" "navigator exposes a Herdr target as a send destination"
assert_no_grep 'fm-pair-compose.sh --' "$DRIVER" "driver names composition flags"
assert_no_grep 'fm-pair-compose.sh --' "$NAVIGATOR" "navigator names composition flags"
assert_no_grep 'agent send' "$HELPER" "runtime delivery uses raw herdr agent send"
assert_no_grep 'pane send-text' "$HELPER" "runtime delivery uses raw pane send-text"
assert_grep 'Do not poll it as normal coordination' "$DRIVER" "driver may passively poll history"
assert_grep 'Git status, diff summary, diff, branch, HEAD' "$NAVIGATOR" "navigator lacks direct current-code inspection"
assert_grep 'send `STOP <finding-id>` first' "$NAVIGATOR" "urgent stop is not live-first"
assert_grep 'ACK STOP <id>' "$DRIVER" "driver lacks explicit stop acknowledgement"

pass "paired-review role routing and progressive-disclosure contract"
