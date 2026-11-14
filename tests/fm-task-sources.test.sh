#!/usr/bin/env bash
# Public-command tests for the old-source backlog mapping and the tasks-axi wrapper. The backfill and reconcile scripts that
# once read the old sources are retired: nothing in the tree or the running homes called them.
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
- [ ] owner - Owner task (hold: Pick A) (hold-kind: captain)
- [ ] future - Later (hold: later) (hold-kind: future)
## Done
- [x] recent - Recent (done 2026-10-25)
- [x] old - Old (done 2020-01-01)
EOF
"$ROOT/bin/fm-task.sh" create probe --title Probe --kind ship --repo example/repo
"$ROOT/bin/fm-task.sh" assign probe --to probe
"$ROOT/bin/fm-task.sh" start probe
node --input-type=module - "$ROOT/bin/fm-task-sources-lib.mjs" "$FM_HOME" <<'JS'
const {parseBacklog} = await import(process.argv[2]);
const rows = parseBacklog(process.argv[3], Date.parse('2026-10-25'));
if (rows.some(t => t.assignee !== t.id)) process.exit(1);
JS
"$ROOT/bin/fm-task.sh" block external probe --reason wait --next-actor firstmate
"$ROOT/bin/fm-task.sh" unblock probe
mkdir -p "$FM_HOME/config"
printf 'FM_TASK_BASE_URL=%s\nFM_TASK_TOKEN_FILE=%s\n' "$FM_TASK_BASE_URL" "$FM_TASK_TOKEN_FILE" > "$FM_HOME/config/task-shadow"
cat > "$TMP_ROOT/broken-crew" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP_ROOT/broken-crew"
export FM_TASK_CREW_STATE="$TMP_ROOT/broken-crew"
printf '\n## In flight\n- [ ] unrelated - Unrelated (kind: ship)\n' >> "$FM_HOME/data/backlog.md"
env -u FM_TASK_BASE_URL -u FM_TASK_TOKEN_FILE bash "$ROOT/bin/fm-tasks-axi.sh" add wrapper-added 'Wrapper added task' >/dev/null
"$ROOT/bin/fm-task.sh" show wrapper-added --json | jq -e '.state == "ready"'
bash "$ROOT/bin/fm-tasks-axi.sh" hold wrapper-added --kind external --reason waiting >/dev/null
"$ROOT/bin/fm-task.sh" show wrapper-added --json | jq -e '.state == "blocked" and .blockKind == "external"'
bash "$ROOT/bin/fm-tasks-axi.sh" unhold wrapper-added >/dev/null
"$ROOT/bin/fm-task.sh" show wrapper-added --json | jq -e '.state == "ready"'
bash "$ROOT/bin/fm-tasks-axi.sh" start wrapper-added >/dev/null
"$ROOT/bin/fm-task.sh" show wrapper-added --json | jq -e '.state == "running"'
(cd "$TMP_ROOT" && FM_DATA_OVERRIDE=home/data env -u FM_TASK_BASE_URL -u FM_TASK_TOKEN_FILE bash "$ROOT/bin/fm-tasks-axi.sh" add relative-added 'Relative data task' >/dev/null)
"$ROOT/bin/fm-task.sh" show relative-added --json | jq -e '.taskId == "relative-added"'
echo 'ok - old-source backlog mapping and wrapper add/hold/unhold/start'
