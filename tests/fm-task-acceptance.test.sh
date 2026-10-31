#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Exercise the parser's executable task read boundary without API credentials.
# The external task reader is controlled here; live persistence proof is separate.
cat > "$TMP/task" <<'SH'
#!/usr/bin/env bash
[ "$1" = document ] && [ "$2" = acceptance-probe ] || exit 1
cat "$DESCRIPTION"
SH
chmod +x "$TMP/task"
export FM_ACCEPTANCE_TASK="$TMP/task" DESCRIPTION="$TMP/description.md"
cat > "$DESCRIPTION" <<'MD'
## Context
Probe.
## Requirements
Read task acceptance.
## Definition of done
Scenario passes.
## Scenarios
- [ ] P1 WHEN a worker reads a task, THE parser SHALL retain its acceptance.
  - page: -
  - widths: -
  - controls: -
  - env: Dev 5001
  - proof: command readback
  - data: probe
  - mock: none
  - surface: internal
## Mockup
None.
## Links
None.
## Decisions
None.
MD
node "$ROOT/bin/fm-acceptance.mjs" parse acceptance-probe --strict > "$TMP/parsed"
jq -e '.problems == [] and .scenarios[0].env == "Dev 5001" and .scenarios[0].mock == "none"' "$TMP/parsed" >/dev/null
node "$ROOT/bin/fm-acceptance.mjs" digest acceptance-probe --strict > "$TMP/digest"
grep -Eq '^[a-f0-9]{64}$' "$TMP/digest"
# A reader failure must refuse rather than return empty acceptance.
export FM_ACCEPTANCE_TASK=/nonexistent/task-reader
if node "$ROOT/bin/fm-acceptance.mjs" parse acceptance-probe --strict > /dev/null 2>&1; then
  echo 'FAIL: missing task reader accepted'; exit 1
fi
printf '%s\n' 'PASS: task Description reader, environment/mock, digest, missing-reader refusal'
