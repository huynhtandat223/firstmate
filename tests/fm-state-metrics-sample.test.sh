#!/usr/bin/env bash
# Sampler integration with the actual feed's {inbox,inboxNav} response shape.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-state-metrics-sample)
trap 'kill "${API_PID:-0}" "${FEED_PID:-0}" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/home/state"
printf token > "$TMP_ROOT/token"; chmod 600 "$TMP_ROOT/token"
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP_ROOT/port" "$ROOT/tests/fm-task-fake-api/schema.json" token &
API_PID=$!
cat > "$TMP_ROOT/feed.mjs" <<'JS'
import http from 'node:http';
import fs from 'node:fs';
const server=http.createServer((req,res)=>{res.setHeader('content-type','application/json');res.end(JSON.stringify({inbox:[{id:'question-guid',task:'held',kind:'question'},{id:'plan:planned',task:'planned',kind:'plan'}],inboxNav:[]}));});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[2],String(server.address().port)));
JS
node "$TMP_ROOT/feed.mjs" "$TMP_ROOT/feedport" &
FEED_PID=$!
for _ in {1..100}; do [ ! -s "$TMP_ROOT/port" ] || [ ! -s "$TMP_ROOT/feedport" ] || break; sleep .1; done
FM_TASK_BASE_URL="http://127.0.0.1:$(<"$TMP_ROOT/port")"
FEED="http://127.0.0.1:$(<"$TMP_ROOT/feedport")"
export FM_TASK_BASE_URL FM_TASK_TOKEN_FILE="$TMP_ROOT/token" FM_HOME="$TMP_ROOT/home"
unset FM_TASK_AUTH
printf '## Queued\n- [ ] held - Held (hold-kind: captain) (hold: Pick)\n' > "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-state-metrics" sample --feed "$FEED" --shadow "$TMP_ROOT/shadow" > "$TMP_ROOT/out"
jq -e '.cards == [{id:"held",key:"hold:held"},{id:"planned",key:"plan:planned"}] and any(.items[]; .key == "hold:held" and .open)' "$TMP_ROOT/out"
echo 'ok - sampler decodes real inbox shape and question task identity'
