#!/usr/bin/env bash
# Source mapping consumes the crew-state public verdict, never the task record.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-source-state)
trap fm_test_cleanup EXIT
mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/home/state"
printf '## In flight\n- [ ] task - Task (kind: ship)\n' > "$TMP_ROOT/home/data/backlog.md"
printf 'blocked [at=123]: waiting\n' > "$TMP_ROOT/home/state/task.status"
cat > "$TMP_ROOT/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: blocked · source: status-log · waiting\n'
SH
chmod +x "$TMP_ROOT/crew-state"
FM_TASK_CREW_STATE="$TMP_ROOT/crew-state" node --input-type=module - "$ROOT/bin/fm-task-sources-lib.mjs" "$TMP_ROOT/home" <<'JS'
const {parseBacklog}=await import(process.argv[2]);
const row=parseBacklog(process.argv[3])[0];
if(row.state!=='blocked'||row.nextActor!=='firstmate')process.exit(1);
JS
mkdir -p "$TMP_ROOT/override"
printf '## Queued\n- [ ] override - Override (kind: ship)\n' > "$TMP_ROOT/override/backlog.md"
FM_DATA_OVERRIDE="$TMP_ROOT/override" node --input-type=module - "$ROOT/bin/fm-task-sources-lib.mjs" "$TMP_ROOT/home" <<'JS'
const {parseBacklog}=await import(process.argv[2]);
if(parseBacklog(process.argv[3])[0].id!=='override')process.exit(1);
JS
printf 'ok - source mapping and data override\n'
