#!/usr/bin/env bash
# Public-command tests for shadow backfill and reconciliation.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BIN=${FM_TASK_SOURCES_BIN:-$ROOT/bin}
TMP_ROOT=$(fm_test_tmproot fm-task-sources)
trap 'kill "${PID:-0}" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/home/state/probe.inbox/handled"
printf token > "$TMP_ROOT/token"; chmod 600 "$TMP_ROOT/token"
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP_ROOT/port" "$ROOT/tests/fm-task-fake-api/schema.json" token &
PID=$!
for _ in {1..100}; do [ ! -s "$TMP_ROOT/port" ] || break; sleep .1; done
FM_TASK_BASE_URL="http://127.0.0.1:$(<"$TMP_ROOT/port")"
export FM_TASK_BASE_URL FM_TASK_TOKEN_FILE="$TMP_ROOT/token" FM_HOME="$TMP_ROOT/home"
cat > "$FM_HOME/data/backlog.md" <<'EOF'
## In flight
- [ ] probe - Probe task (repo: example/repo) (kind: ship)
  A note.
## Queued
- [ ] owner - Owner task (hold-kind: captain) (hold: Pick A)
- [ ] future - Later (hold-kind: future)
## Done
- [x] recent - Recent (done: 2026-10-25)
- [x] old - Old (done: 2020-01-01)
EOF
printf 'working [at=123]: doing work\n' > "$FM_HOME/state/probe.status"
printf 'one instruction\n' > "$FM_HOME/state/probe.inbox/handled/1.msg"
bash "$BIN/fm-task-backfill.sh" --now 2026-10-25T14:00:00Z --dry-run > "$TMP_ROOT/dry"
grep -q 'running=1' "$TMP_ROOT/dry"
bash "$BIN/fm-task-backfill.sh" --now 2026-10-25T14:00:00Z > "$TMP_ROOT/first"
bash "$BIN/fm-task-backfill.sh" --now 2026-10-25T14:00:00Z > "$TMP_ROOT/second"
grep -q '^0 added' "$TMP_ROOT/second"
curl -fsS "$FM_TASK_BASE_URL/__x/rows/fm_task_event" | jq -e 'any(.[]; .kind == "steer") and any(.[]; .kind == "comment" and (.body | contains("probe.status")))'
"$ROOT/bin/fm-task.sh" list --json > "$TMP_ROOT/list"
jq -e 'length == 4 and any(.[]; .taskId == "owner" and .blockKind == "needs-decision" and .nextActor == "owner") and any(.[]; .taskId == "future" and .state == "todo")' "$TMP_ROOT/list"
"$ROOT/bin/fm-task.sh" event probe comment --note untouched --key untouched
"$ROOT/bin/fm-task.sh" show probe --json > "$TMP_ROOT/before"
sed -i 's/## In flight/## Queued/' "$FM_HOME/data/backlog.md"
bash "$ROOT/bin/fm-task-reconcile.sh" once --now 2026-10-25T14:00:00Z > "$TMP_ROOT/reconcile"
jq -e '.added == 2' "$TMP_ROOT/reconcile"
bash "$ROOT/bin/fm-task-reconcile.sh" once --now 2026-10-25T14:00:00Z > "$TMP_ROOT/repeat"
jq -e '.added == 0' "$TMP_ROOT/repeat"
# Divergence events change lastSeq only, not the old source or projected values.
"$ROOT/bin/fm-task.sh" show probe --json > "$TMP_ROOT/after"
diff <(jq 'del(.lastSeq)' "$TMP_ROOT/before") <(jq 'del(.lastSeq)' "$TMP_ROOT/after")
node --input-type=module - "$ROOT/bin/fm-task-sources-lib.mjs" "$FM_HOME" <<'JS'
const {parseBacklog} = await import(process.argv[2]);
const rows = parseBacklog(process.argv[3], Date.parse('2026-10-25'));
if (rows.some(t => t.assignee !== t.id)) process.exit(1);
JS
"$ROOT/bin/fm-task.sh" block external probe --reason wait --next-actor firstmate
"$ROOT/bin/fm-task.sh" unblock probe
# No hold remains in the old source; stale blockKind must not count as a difference.
bash "$ROOT/bin/fm-task-reconcile.sh" once --now 2026-10-25T14:00:00Z > "$TMP_ROOT/normalized"
jq -e '.added == 0' "$TMP_ROOT/normalized"
# A check awaiting its owner must have a matching owner checklist item.
curl -fsS -H 'Authorization: Bearer token' -H 'content-type: application/json' -X POST "$FM_TASK_BASE_URL/api/fm_task_check" --data '{"taskId":"probe","scenarioId":"OWNER","width":"-","line":"Owner check","surface":"internal","page":"-","controls":"-","data":"probe","proof":"manual","status":"pending","nextActor":"owner","acceptanceDigest":"probe"}' > /dev/null
bash "$BIN/fm-task-reconcile.sh" once --now 2026-10-25T14:00:00Z > "$TMP_ROOT/pairing"
jq -e '.added == 1' "$TMP_ROOT/pairing"
bash "$ROOT/bin/fm-task-reconcile.sh" once --now 2026-10-25T14:00:00Z > "$TMP_ROOT/pairing-repeat"
jq -e '.added == 0' "$TMP_ROOT/pairing-repeat"
echo 'ok - backfill mapping, history idempotency, reconciliation, no repair, owner pairing'
