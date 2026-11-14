#!/usr/bin/env bash
# Public CLI contract against a controlled API boundary; live 5001 proof is separate.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'kill "${SERVER:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
printf token > "$TMP/token"; chmod 600 "$TMP/token"
cat > "$TMP/server.mjs" <<'JS'
import http from 'node:http';
import fs from 'node:fs';
const tables = {fm_host:[],fm_home_lease:[]};
const server = http.createServer(async (req,res) => {
 const u=new URL(req.url,'http://localhost'); const [, ,table,id]=u.pathname.split('/');
 let body=''; for await (const part of req) body+=part;
 let rows=tables[table]; if(!rows) {res.writeHead(404).end(); return;}
 let status=200, result;
 if(req.method==='GET') {
  const filter=u.searchParams.get('$filter');
  rows=rows.filter(r=>!filter || (filter.startsWith('home eq')?r.home:r.hostId)===filter.match(/'([^']+)'/)[1]);
  if(u.searchParams.get('$orderby')==='generation desc') rows=rows.toSorted((a,b)=>b.generation-a.generation);
  result={value:rows};
 } else if(req.method==='POST') {
  const value=JSON.parse(body);
  // <port file>.race makes one competing take land first on the same generation.
  const race=process.argv[2]+'.race';
  if(table==='fm_home_lease'&&fs.existsSync(race)) {fs.unlinkSync(race);rows.push({...value,id:String(rows.length+1),hostId:'probe-racer'});}
  if(rows.some(r=>table==='fm_host'?r.hostId===value.hostId:r.home===value.home&&r.generation===value.generation)) status=409;
  else {value.id=String(rows.length+1);rows.push(value);result=value;}
 } else if(req.method==='PATCH') {
  const row=rows.find(r=>r.id===id); if(!row) status=404; else {Object.assign(row,JSON.parse(body)); result=row;}
 }
 res.writeHead(status,{'content-type':'application/json'}).end(JSON.stringify(result||{}));
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[2],String(server.address().port)));
JS
node "$TMP/server.mjs" "$TMP/port" & SERVER=$!
for ((i=0;i<100;i++)); do [ ! -f "$TMP/port" ] || break; sleep .02; done
FM_TASK_BASE_URL="http://127.0.0.1:$(< "$TMP/port")"
export FM_TASK_BASE_URL FM_TASK_TOKEN_FILE="$TMP/token" FM_HOME="$TMP/home" FM_HOME_NAME=probe FM_HOST_ID=probe-a
run() { bash "$ROOT/bin/fm-host.sh" "$@"; }
run register >/dev/null
run lease take --json > "$TMP/first"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); if(r.hostId!=="probe-a"||r.generation!==1)process.exit(1)' "$TMP/first"
FM_HOST_ID=probe-b run register >/dev/null
if FM_HOST_ID=probe-b run lease take > "$TMP/refused"; then echo 'FAIL competing host took live lease'; exit 1; fi
grep -q 'held by probe-a' "$TMP/refused"
FM_HOST_LIVE_WORKERS=1 FM_HOST_WAKE_QUEUE_LENGTH=2 run heartbeat >/dev/null
if FM_HOST_LIVE_WORKERS=0 run lease release >/dev/null; then echo 'FAIL released with workers'; exit 1; fi
FM_HOST_LIVE_WORKERS=0 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null
FM_HOST_LIVE_WORKERS=0 run lease release >/dev/null
FM_HOST_ID=probe-b run lease take --json > "$TMP/second"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.hostId!=="probe-b"||r.generation!==2)process.exit(1)' "$TMP/second"
if FM_HOST_LIVE_WORKERS=0 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null; then echo 'FAIL old host renewed'; exit 1; fi
# A worker claim needs the lease and raises the recorded count, which then blocks a release.
if run worker claim w1 >/dev/null; then echo 'FAIL a non-holder claimed a worker'; exit 1; fi
FM_HOST_ID=probe-b run worker claim w1 --json | grep -q '"liveWorkers":1' || { echo 'FAIL worker claim did not raise liveWorkers'; exit 1; }
if FM_HOST_ID=probe-b FM_HOST_LIVE_WORKERS=0 run lease release >/dev/null; then echo 'FAIL released over a claimed worker'; exit 1; fi
FM_HOST_ID=probe-b FM_HOST_LIVE_WORKERS=0 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null
# A holder whose lease expired while its workers live (a restart) takes it back; another host still waits.
FM_HOST_ID=probe-b FM_HOST_LIVE_WORKERS=2 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null
cat > "$TMP/expire.mjs" <<'JS'
const base = process.argv[2], q = encodeURIComponent(`home eq '${process.argv[3] || 'probe'}'`);
const row = (await (await fetch(`${base}/api/fm_home_lease?$filter=${q}&$orderby=generation%20desc`)).json()).value[0];
await fetch(`${base}/api/fm_home_lease/${row.id}`, { method: 'PATCH', body: JSON.stringify({ heartbeatAt: new Date(Date.now() - 600000).toISOString() }) });
JS
node "$TMP/expire.mjs" "$FM_TASK_BASE_URL"
if FM_HOST_ID=probe-b run lease check >/dev/null; then echo 'FAIL an expired lease passed the check'; exit 1; fi
if run lease take > "$TMP/expired-refused"; then echo 'FAIL another host took an expired lease over live workers'; exit 1; fi
grep -q 'held by probe-b' "$TMP/expired-refused"
FM_HOST_ID=probe-b run lease take --json > "$TMP/retaken" || { echo "FAIL the holder could not take back its own expired lease: $(cat "$TMP/retaken")"; exit 1; }
# It retakes through generation+1, the generation a competing take would conflict on, never by renewing in place.
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.hostId!=="probe-b"||r.generation!==3||Date.now()-Date.parse(r.heartbeatAt)>60000)process.exit(1)' "$TMP/retaken" || { echo "FAIL the holder renewed in place instead of taking a new generation: $(cat "$TMP/retaken")"; exit 1; }
FM_HOST_ID=probe-b run lease check >/dev/null
FM_HOST_ID=probe-b FM_HOST_LIVE_WORKERS=0 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null
# With no workers counted, the holder also retakes through a new generation.
node "$TMP/expire.mjs" "$FM_TASK_BASE_URL"
FM_HOST_ID=probe-b run lease take --json > "$TMP/retaken-idle"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));if(r.hostId!=="probe-b"||r.generation!==4)process.exit(1)' "$TMP/retaken-idle" || { echo "FAIL an idle holder renewed in place instead of taking a new generation: $(cat "$TMP/retaken-idle")"; exit 1; }
# A competing take that lands first on that generation wins, even while the holder counts live workers.
FM_HOME_NAME=probe-race FM_HOST_ID=probe-b run lease take >/dev/null
FM_HOST_ID=probe-b FM_HOST_LIVE_WORKERS=2 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null
node "$TMP/expire.mjs" "$FM_TASK_BASE_URL" probe-race
: > "$TMP/port.race"
if FM_HOME_NAME=probe-race FM_HOST_ID=probe-b run lease take > "$TMP/raced"; then echo 'FAIL the holder and a competing take both took the expired lease'; exit 1; fi
grep -q 'ownership race lost' "$TMP/raced"
FM_HOST_ID=probe-b FM_HOST_LIVE_WORKERS=0 FM_HOST_WAKE_QUEUE_LENGTH=0 run heartbeat >/dev/null
if run register --typo >/dev/null; then echo 'FAIL unknown flag accepted'; exit 1; fi
# A configured authorization seam refuses an old host; an unconfigured home is unchanged.
mkdir -p "$FM_HOME/config"; printf probe > "$FM_HOME/config/home-lease"
if bash -c 'source "$1/bin/fm-home-lease-lib.sh"; fm_home_lease_require' _ "$ROOT"; then echo 'FAIL old host authorized'; exit 1; fi
FM_HOST_ID=probe-b bash -c 'source "$1/bin/fm-home-lease-lib.sh"; fm_home_lease_require' _ "$ROOT"
rm "$FM_HOME/config/home-lease"
bash -c 'source "$1/bin/fm-home-lease-lib.sh"; fm_home_lease_require' _ "$ROOT"
# Two machines with one hostname get distinct, persisted ids and only the holder passes the lease check.
anon() { local m=$1; shift; env -u FM_HOST_ID FM_HOME="$TMP/$m" FM_HOME_NAME=probe-id bash "$ROOT/bin/fm-host.sh" "$@"; }
anon m1 register --json > "$TMP/m1-register"
anon m2 register --json > "$TMP/m2-register"
id1=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).hostId)' "$TMP/m1-register")
id2=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).hostId)' "$TMP/m2-register")
[ "$id1" != "$id2" ] || { echo "FAIL two machines with one hostname share host id $id1"; exit 1; }
[ "$(tr -d '\n' < "$TMP/m1/config/host-id")" = "$id1" ] || { echo 'FAIL host id was not persisted'; exit 1; }
anon m1 register --json | grep -q "\"hostId\":\"$id1\"" || { echo 'FAIL host id changed between calls'; exit 1; }
anon m1 lease take >/dev/null
anon m1 lease check >/dev/null
if anon m2 lease check >/dev/null; then echo 'FAIL a second machine with the same hostname passed the lease check'; exit 1; fi
echo 'PASS public host registry, lease contention, transfer, worker protection, old-holder refusal and opt-in compatibility (controlled API; live proof pending)'
