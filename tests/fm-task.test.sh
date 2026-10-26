#!/usr/bin/env bash
# Behavior tests for bin/fm-task.sh, the one writer and reader of the task contract.
#
# Every case drives the real command against a local stand-in for Dev 5001 (a small
# HTTP server written below). The stand-in applies the rules the published tables
# carry: required and length rules on a root row and on each deep-insert child,
# unique keys answering 409 with details.existingId, a missing int stored as 0,
# server values, an undeclared verb answering 404, and OData $filter/$orderby/$top.
# It also counts requests, so a case can show that an event and its child travel in one.
# The same command runs against the real 5001 on probe rows for the scenario proofs
# (tr10 to tr15); that run is recorded with the delivery, not repeated here.
#
# Each case takes a bin directory. The mutation proofs at the end copy the command,
# remove one guard, and show the case that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { printf 'skip - node is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'

TMP_ROOT=$(fm_test_tmproot fm-task)
mkdir -p "$TMP_ROOT/fakebin"
TOKEN="tok-$$-$RANDOM"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
chmod 600 "$TMP_ROOT/token"

# ---- the stand-in for Dev 5001 ------------------------------------------------

cat > "$TMP_ROOT/schema.json" <<'JSON'
{"fm_task":{"ops":["list","get","create","patch"],"f":{"assignee":{"t":"s","m":64},"blockKind":{"t":"s","n":1,"m":32},"blockReason":{"t":"s","n":1,"m":2000},"blockRepeats":{"t":"i"},"createdAt":{"t":"d","sv":"now"},"createdBy":{"t":"s","m":64,"sv":"callerId"},"holdUntil":{"t":"d","n":1},"issueUrl":{"t":"s","n":1,"m":2048},"kind":{"t":"s","m":32},"lastSeq":{"t":"i"},"nextActor":{"t":"s","m":32},"prUrl":{"t":"s","n":1,"m":2048},"repo":{"t":"s","n":1,"m":200},"state":{"t":"s","m":32},"surface":{"t":"s","n":1,"m":32},"taskId":{"t":"s","m":128},"title":{"t":"s","m":300}},"u":[["taskId"]]},"fm_task_event":{"ops":["list","get","create"],"f":{"actor":{"t":"s","m":64},"actorRole":{"t":"s","m":32},"body":{"t":"s","m":8000},"createdAt":{"t":"d","sv":"now"},"createdBy":{"t":"s","m":64,"sv":"callerId"},"idempotencyKey":{"t":"s","m":200},"kind":{"t":"s","m":32},"seq":{"t":"i"},"taskId":{"t":"s","m":128}},"u":[["seq"],["idempotencyKey"]]},"fm_event_done":{"ops":["list","get","create"],"f":{"changedFiles":{"t":"s","m":4000},"head":{"t":"s","n":1,"m":64},"prUrl":{"t":"s","n":1,"m":2048},"residualRisk":{"t":"s","m":2000},"rows":{"t":"s"},"summary":{"t":"s","m":4000},"verification":{"t":"s","m":4000}},"u":[["fmTaskEventId"]],"parent":["fmTaskEvent","done"]},"fm_event_question":{"ops":["list","get","create"],"f":{"document":{"t":"s","n":1,"m":2048},"options":{"t":"s","m":8000},"question":{"t":"s","m":2000},"recommendation":{"t":"s","m":2000},"why":{"t":"s","m":4000}},"u":[["fmTaskEventId"]],"parent":["fmTaskEvent","question"]},"fm_event_block":{"ops":["list","get","create"],"f":{"blockKind":{"t":"s","m":32},"nextActor":{"t":"s","m":32},"reason":{"t":"s","m":2000},"until":{"t":"d","n":1}},"u":[["fmTaskEventId"]],"parent":["fmTaskEvent","block"]},"fm_event_image":{"ops":["list","get","create"],"f":{"content":{"t":"s"},"label":{"t":"s","m":200},"mediaType":{"t":"s","m":32},"position":{"t":"i","n":1}},"u":[],"parent":["fmTaskEvent","images"]},"fm_task_check":{"ops":["list","get","create","patch"],"f":{"acceptanceDigest":{"t":"s","m":128},"checkedAt":{"t":"d","n":1},"controls":{"t":"s","m":2000},"data":{"t":"s","m":2000},"evidence":{"t":"s","n":1,"m":4000},"head":{"t":"s","n":1,"m":64},"line":{"t":"s","m":4000},"nextActor":{"t":"s","m":32},"page":{"t":"s","m":200},"proof":{"t":"s","m":4000},"scenarioId":{"t":"s","m":64},"status":{"t":"s","m":32},"surface":{"t":"s","m":32},"taskId":{"t":"s","m":128},"width":{"t":"s","m":32}},"u":[["taskId","scenarioId","width"]]},"fm_owner_check":{"ops":["list","get","create","patch"],"f":{"data":{"t":"s","m":4000},"decidedAt":{"t":"d","n":1},"expected":{"t":"s","m":4000},"note":{"t":"s","n":1,"m":4000},"pageTitle":{"t":"s","m":200},"scenarioId":{"t":"s","m":64},"status":{"t":"s","m":16},"steps":{"t":"s","m":8000},"taskId":{"t":"s","m":128},"url":{"t":"s","m":2048},"width":{"t":"s","m":32}},"u":[["taskId","scenarioId","width"]]},"fm_task_link":{"ops":["list","get","create","delete"],"f":{"childTaskId":{"t":"s","m":128},"parentTaskId":{"t":"s","m":128}},"u":[["parentTaskId","childTaskId"]]},"fm_task_delivery":{"ops":["list","get","create"],"f":{"consumer":{"t":"s","m":64},"deliveredAt":{"t":"d","sv":"now"},"seq":{"t":"i"}},"u":[["consumer","seq"]]}}
JSON
node - "$TMP_ROOT/schema.json" <<'JS'
const fs = require('fs');
const file = process.argv[2]; const s = JSON.parse(fs.readFileSync(file));
s.fm_event_document = {ops:['list','get','create'],f:{title:{t:'s',m:200},mediaType:{t:'s',m:100},content:{t:'s'}},u:[['fmTaskEventId']],parent:['fmTaskEvent','documents']};
fs.writeFileSync(file, JSON.stringify(s));
JS

cat > "$TMP_ROOT/fake-api.mjs" <<'JS'
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';

const [portFile, schemaFile, token] = process.argv.slice(2);
const SCHEMA = JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
const camel = (s) => s.split('_').map((p, i) => (i ? p[0].toUpperCase() + p.slice(1) : p)).join('');
const pascal = (s) => s[0].toUpperCase() + s.slice(1);
const db = {};
const NAVS = {};
for (const table of Object.keys(SCHEMA)) db[table] = [];
for (const [table, def] of Object.entries(SCHEMA)) {
  if (!def.parent) continue;
  const parent = Object.keys(SCHEMA).find((t) => camel(t) === def.parent[0]);
  (NAVS[parent] ||= {})[def.parent[1]] = table;
}
let log = [];
let rivals = 0;
let lose = { mode: '', n: 0 };
let delay = { table: '', ms: 0, n: 0, verb: 'patch' };

const reply = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
const refusal = (status, errorCode, message, details = null) => ({ status, body: { success: false, data: null, errorCode, message, details } });

function normalize(table, body, partial) {
  const errors = {};
  const row = {};
  for (const [name, f] of Object.entries(SCHEMA[table].f)) {
    const present = Object.prototype.hasOwnProperty.call(body, name);
    if (f.sv) {
      if (present) errors[pascal(name)] = 'INVALID_WRITE';
      continue;
    }
    if (!present) {
      if (partial) continue;
      if (f.t === 'i') row[name] = 0;
      else if (f.n) row[name] = null;
      else errors[pascal(name)] = `The ${pascal(name)} field is required.`;
      continue;
    }
    const v = body[name];
    if (v === null) {
      if (f.n) row[name] = null;
      else errors[pascal(name)] = `The ${pascal(name)} field is required.`;
      continue;
    }
    if (f.t === 's' && typeof v !== 'string') errors[pascal(name)] = `The ${pascal(name)} field must be a string.`;
    else if (f.t === 'i' && !Number.isInteger(v)) errors[pascal(name)] = `The ${pascal(name)} field must be an integer.`;
    else if (f.t === 'd' && Number.isNaN(Date.parse(v))) errors[pascal(name)] = `The ${pascal(name)} field must be a date.`;
    else if (f.m && typeof v === 'string' && v.length > f.m) errors[pascal(name)] = `The field ${pascal(name)} must be a string with a maximum length of ${f.m}.`;
    else row[name] = v;
  }
  return { errors, row };
}

function conflict(table, row, exceptId) {
  for (const group of SCHEMA[table].u) {
    const hit = db[table].find((r) => r.id !== exceptId && group.every((k) => r[k] === row[k]));
    if (hit) return refusal(409, 'UNIQUE_KEY_CONFLICT', `A ${table} row with the same (${group.join(', ')}) already exists.`, { key: group, existingId: hit.id });
  }
  return null;
}

function create(table, body) {
  const { errors, row } = normalize(table, body, false);
  const children = [];
  for (const [nav, childTable] of Object.entries(NAVS[table] || {})) {
    if (body[nav] === undefined) continue;
    if (!Array.isArray(body[nav])) {
      errors[pascal(nav)] = 'must be an array';
      continue;
    }
    body[nav].forEach((child, i) => {
      const n = normalize(childTable, child, false);
      for (const [k, v] of Object.entries(n.errors)) errors[`${pascal(nav)}[${i}].${k}`] = v;
      children.push([childTable, n.row]);
    });
  }
  if (Object.keys(errors).length) return refusal(400, 'VALIDATION_ERROR', 'One or more validation errors occurred.', errors);
  const clash = conflict(table, row, null);
  if (clash) return clash;
  const id = crypto.randomUUID();
  const stored = { id, ...row };
  for (const [name, f] of Object.entries(SCHEMA[table].f)) {
    if (f.sv === 'now') stored[name] = new Date().toISOString();
    if (f.sv === 'callerId') stored[name] = 'caller-1';
  }
  db[table].push(stored);
  for (const [childTable, childRow] of children) {
    const child = { id: crypto.randomUUID(), ...childRow, fmTaskEventId: id };
    for (const [name, f] of Object.entries(SCHEMA[childTable].f)) if (f.sv === 'now') child[name] = new Date().toISOString();
    db[childTable].push(child);
  }
  return { status: 201, body: { success: true, data: stored, errorCode: null, message: null, details: null } };
}

function patch(table, id, body) {
  const target = db[table].find((r) => r.id === id);
  if (!target) return refusal(404, 'NOT_FOUND', `${table} ${id} not found.`);
  const { errors, row } = normalize(table, body, true);
  if (Object.keys(errors).length) return refusal(400, 'VALIDATION_ERROR', 'One or more validation errors occurred.', errors);
  const next = { ...target, ...row };
  const clash = conflict(table, next, id);
  if (clash) return clash;
  Object.assign(target, row);
  return { status: 200, body: { success: true, data: target, errorCode: null, message: null, details: null } };
}

const literal = (text) => {
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text)) return { guid: text };
  if (/^'.*'$/s.test(text)) return text.slice(1, -1).replaceAll("''", "'");
  if (text === 'true') return true;
  if (text === 'false') return false;
  if (text === 'null') return null;
  return Number(text);
};

function list(table, query) {
  let rows = db[table];
  const filter = query.get('$filter');
  if (filter) {
    for (const clause of filter.split(/ and /)) {
      const m = /^(\w+) (eq|ne|gt|ge|lt|le) (.+)$/s.exec(clause.trim());
      if (!m || !(m[1] in SCHEMA[table].f || m[1] === 'id' || m[1] === 'fmTaskEventId')) return refusal(400, 'INVALID_QUERY', `Could not find a property named '${m ? m[1] : clause}' on type ${table}.`);
      let want = literal(m[3]);
      const isGuid = m[1] === 'id' || m[1] === 'fmTaskEventId';
      // the real API types these two as Edm.Guid: a quoted string is refused, a bare guid is the only literal
      if (isGuid !== (typeof want === 'object' && want !== null)) return refusal(400, 'INVALID_QUERY', `A binary operator with incompatible types was detected on '${m[1]}'.`);
      if (isGuid) want = want.guid;
      const op = { eq: (a) => a === want, ne: (a) => a !== want, gt: (a) => a > want, ge: (a) => a >= want, lt: (a) => a < want, le: (a) => a <= want }[m[2]];
      rows = rows.filter((r) => op(r[m[1]]));
    }
  }
  const order = query.get('$orderby');
  if (order) {
    const [field, dir] = order.split(' ');
    rows = [...rows].sort((a, b) => (a[field] > b[field] ? 1 : a[field] < b[field] ? -1 : 0) * (dir === 'desc' ? -1 : 1));
  }
  const top = query.has('$top') ? Number(query.get('$top')) : 100;
  if (top > 100) return refusal(400, 'INVALID_QUERY', `The limit of '100' for Top query has been exceeded. The value from the incoming request is '${top}'.`);
  const skip = Number(query.get('$skip') || 0);
  const out = { value: rows.slice(skip, skip + top) };
  if (query.get('$count') === 'true') out['@odata.count'] = rows.length;
  return { status: 200, body: out };
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://x');
    const raw = Buffer.concat(chunks).toString('utf8');
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] === '__x') {
      if (parts[1] === 'rows') return reply(res, 200, db[parts[2]] || []);
      if (parts[1] === 'log') {
        if (req.method === 'POST') log = [];
        return reply(res, 200, log);
      }
      if (parts[1] === 'rival') {
        rivals = Number(url.searchParams.get('n') || 0);
        return reply(res, 200, { rivals });
      }
      if (parts[1] === 'lose') {
        lose = { mode: url.searchParams.get('mode') || '', n: Number(url.searchParams.get('n') || 1) };
        return reply(res, 200, lose);
      }
      if (parts[1] === 'delay') {
        delay = { table: parts[2], ms: Number(url.searchParams.get('ms') || 0), n: Number(url.searchParams.get('n') || 1), verb: url.searchParams.get('verb') || 'patch' };
        return reply(res, 200, delay);
      }
      if (parts[1] === 'drop') {
        db[parts[2]] = db[parts[2]].filter((r) => r.id !== parts[3]);
        return reply(res, 200, {});
      }
      if (parts[1] === 'reset') {
        for (const t of Object.keys(db)) db[t] = [];
        log = [];
        rivals = 0;
        lose = { mode: '', n: 0 };
        delay = { table: '', ms: 0, n: 0, verb: 'patch' };
        return reply(res, 200, {});
      }
      return reply(res, 404);
    }
    let body = {};
    try {
      body = raw ? JSON.parse(raw) : {};
    } catch {
      return reply(res, 400, { success: false, errorCode: 'INVALID_JSON' });
    }
    log.push({ method: req.method, path: url.pathname, body });
    const bearer = req.headers.authorization === `Bearer ${token}`;
    const cookie = /(?:^|;\s*)cfw\.auth\.session=([^;]*)/.exec(req.headers.cookie || '')?.[1] === token;
    if (!bearer && !cookie) return reply(res, 401, { success: false, data: null, errorCode: 'API_REQUIRES_SIGN_IN', message: 'requires a signed-in caller' });
    const [api, table, id] = parts;
    if (api !== 'api' || !SCHEMA[table]) return reply(res, 404);
    const verb = { GET: id ? 'get' : 'list', POST: 'create', PATCH: 'patch', DELETE: 'delete' }[req.method];
    if (!verb || !SCHEMA[table].ops.includes(verb)) return reply(res, 404);
    let out;
    if (verb === 'list' && delay.n > 0 && delay.verb === 'list' && delay.table === table) {
      // the read is held before it is answered, so a later call can finish first
      delay.n--;
      return setTimeout(() => {
        const late = list(table, url.searchParams);
        reply(res, late.status, late.body);
      }, delay.ms);
    }
    if (verb === 'list') out = list(table, url.searchParams);
    else if (verb === 'get') {
      const row = db[table].find((r) => r.id === id);
      out = row ? { status: 200, body: { success: true, data: row } } : refusal(404, 'NOT_FOUND', 'not found');
    } else if (verb === 'patch') {
      if (delay.n > 0 && delay.verb === 'patch' && delay.table === table) {
        // the patch is held before it is applied, so a later call can finish first
        delay.n--;
        return setTimeout(() => {
          const late = patch(table, id, body);
          reply(res, late.status, late.body);
        }, delay.ms);
      }
      out = patch(table, id, body);
    }
    else if (verb === 'delete') {
      db[table] = db[table].filter((r) => r.id !== id);
      return reply(res, 204);
    } else {
      if (table === 'fm_task_event' && lose.n > 0 && lose.mode === 'before') {
        lose.n--;
        return reply(res, 503, { success: false, errorCode: 'UNAVAILABLE' });
      }
      if (table === 'fm_task_event' && rivals > 0) {
        rivals--;
        const top = Math.max(0, ...db.fm_task_event.map((r) => r.seq));
        create('fm_task_event', { seq: top + 1, taskId: 'rival', kind: 'comment', actorRole: 'system', actor: 'rival', body: '{}', idempotencyKey: `rival-${crypto.randomUUID()}` });
      }
      out = create(table, body);
      if (table === 'fm_task_event' && lose.n > 0 && lose.mode === 'after') {
        lose.n--;
        return reply(res, 503, { success: false, errorCode: 'UNAVAILABLE' });
      }
    }
    return reply(res, out.status, out.body);
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
const parent = process.ppid;
setInterval(() => {
  try {
    process.kill(parent, 0);
  } catch {
    process.exit(0);
  }
}, 1000).unref();
setTimeout(() => process.exit(0), 20 * 60 * 1000).unref();
JS

cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = issue ] && [ "${2:-}" = view ] && [ "${4:-}" = --json ] && [ "${5:-}" = body ] || exit 2
jq -Rs '{body: .}' "$FAKE_GH_BODY_FILE"
SH
chmod +x "$TMP_ROOT/fakebin/gh"

node "$TMP_ROOT/fake-api.mjs" "$TMP_ROOT/port" "$TMP_ROOT/schema.json" "$TOKEN" &
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/port" ] && break; sleep 0.1; done
[ -s "$TMP_ROOT/port" ] || fail 'the stand-in API did not start'
PORT=$(cat "$TMP_ROOT/port")
BASE="http://127.0.0.1:$PORT"
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null; fm_test_cleanup' EXIT

export FM_TASK_BASE_URL="$BASE" FM_TASK_TOKEN_FILE="$TMP_ROOT/token" FM_TASK_ACTOR=tester-bot
export FM_ACCEPTANCE_GH="$TMP_ROOT/fakebin/gh" FAKE_GH_BODY_FILE="$TMP_ROOT/issue.body"
unset FM_TASK_AUTH FM_TASK_ROLE
ISSUE=https://github.com/example/repo/issues/1

# ---- helpers ----------------------------------------------------------------------

BIN=$ROOT/bin
OUT='' ERR='' RC=0

ft() {  # <args...>: run the command; OUT, ERR and RC hold its stdout, stderr and exit code
  OUT=$("$BIN/fm-task.sh" "$@" 2>"$TMP_ROOT/err")
  RC=$?
  ERR=$(cat "$TMP_ROOT/err")
  return "$RC"
}
db() { curl -s "$BASE/__x/rows/$1"; }                       # all rows of a table
api() { curl -s -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }
reset_db() { curl -s -X POST "$BASE/__x/reset" >/dev/null; }
posts() { curl -s "$BASE/__x/log" | jq --arg m "$1" --arg p "/api/$2" '[.[] | select(.method == $m and .path == $p)] | length'; }
log_reset() { curl -s -X POST "$BASE/__x/log" >/dev/null; }
task_row() { db fm_task | jq -c --arg t "$1" '.[] | select(.taskId == $t)'; }
task_state() { task_row "$1" | jq -r .state; }
count() { db "$1" | jq length; }
seq_of() { sed -n 's/^seq=\([0-9][0-9]*\).*/\1/p' <<<"$OUT" | head -1; }
must() {  # <label> <expected-rc>: the last ft call exited with the code
  [ "$RC" -eq "$2" ] || { echo "$1: exit $RC, want $2: out=[$OUT] err=[$ERR]"; return 1; }
}

DONE_FLAGS=(--summary 'Built it' --changed-files 'bin/fm-task.sh' --verification 'ran the tests' --residual-risk 'none known')
ASK_FLAGS=(--question 'Which one?' --option 'Option A' --option 'Option B' --recommendation 'Option A' --why 'Both work; A is simpler')

mk_ready() { ft create "$1" --title "Task $1" --kind ship --repo example/repo && ft assign "$1" --to worker-1; }
mk_running() { mk_ready "$1" && ft start "$1"; }

# ---- issue bodies for the rows cases ----------------------------------------------

scenario() {  # <id> <surface> <page> <widths> <line> <proof>
  printf -- '- [ ] %s %s\n' "$1" "$5"
  printf '  - page: %s\n  - widths: %s\n' "$3" "$4"
  if [ "$3" = - ]; then printf '  - controls: -\n'; else printf '  - controls: button "Save"; textbox "Name"\n'; fi
  printf '  - env: Dev 5001\n  - proof: %s\n  - data: the probe row\n  - mock: none\n  - surface: %s\n' "$6" "$2"
}
issue_body() {  # <variant>
  local a1_line='WHEN a user acts, THE page SHALL answer.' a1_w='1440, 390' a2_proof='read the row back' a4=0
  case $1 in
    v2) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a2_proof='read the row back twice'; a4=1 ;;
    v3) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a1_w='1440'; a2_proof='read the row back twice' ;;
    v4) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a1_w='1440'; a2_proof='read the row back twice'; a4=1 ;;
    v5) a1_line='WHEN a user acts, THE page SHALL answer fast.'; a2_proof='read the row back twice' ;;
  esac
  printf '## Context\n\nc\n\n## Requirements\n\nr\n\n## Definition of done\n\nd\n\n## Scenarios\n\n'
  scenario A1 user-visible home "$a1_w" "$a1_line" 'click Save'
  scenario A2 internal - - 'WHEN the writer runs, THE row SHALL be stored.' "$a2_proof"
  scenario A3 internal - - 'WHEN the writer fails, THE row SHALL stay.' 'run it twice'
  [ "$a4" = 0 ] || scenario A4 internal - - 'WHEN the key repeats, THE first row SHALL return.' 'send twice'
  printf '\n## Mockup\n\nnone\n\n## Links\n\nl\n\n## Decisions\n\nx\n'
}
use_issue() { issue_body "$1" > "$TMP_ROOT/issue.body"; }

# ---- cases: each returns 0 when the behavior holds -------------------------------

# TR10: a terminal call stores its event and child in one request and prints the seq;
# a missing template field prints the API's field and stores nothing.
case_terminal() {
  BIN=$1; reset_db
  local badfile docs_before doc_id
  printf '# Report\nUnicode: café\n' > "$TMP_ROOT/report.md"
  printf '<!doctype html><script>window.proof=1</script>café' > "$TMP_ROOT/report.html"
  for badfile in "$TMP_ROOT/report.md" "$TMP_ROOT/report.html"; do
    mk_running doc-valid >/dev/null || return 1
    log_reset
    ft done doc-valid "${DONE_FLAGS[@]}" --document "$badfile"
    must 'document deep insert' 0 || return 1
    doc_id=$(db fm_task_event | jq -r --argjson seq "$(seq_of)" '.[] | select(.seq == $seq) | .id')
    db fm_event_document | jq -e --arg id "$doc_id" --rawfile content "$badfile" --arg title "$(basename "$badfile")" '.[] | select(.fmTaskEventId == $id) | .content == $content and .title == $title and (.mediaType == "text/markdown" or .mediaType == "text/html")' >/dev/null || { echo 'document differs from input bytes'; return 1; }
    [ "$(posts POST fm_task_event)" = 1 ] && [ "$(posts POST fm_event_document)" = 0 ] || return 1
    reset_db
  done
  printf '\377' > "$TMP_ROOT/latin.md"
  : > "$TMP_ROOT/empty.md"
  printf 'plain' > "$TMP_ROOT/wrong.txt"
  mk_running doc-refusal >/dev/null || return 1
  for badfile in "$TMP_ROOT/latin.md" "$TMP_ROOT/empty.md" "$TMP_ROOT/wrong.txt" "$TMP_ROOT/missing.md"; do
    ft done doc-refusal "${DONE_FLAGS[@]}" --document "$badfile"
    must 'invalid document' 2 || return 1
    [ "$(task_state doc-refusal)" = running ] || return 1
  done
  node -e 'require("fs").writeFileSync(process.argv[1], Buffer.alloc(2*1024*1024+1, 65))' "$TMP_ROOT/large.md"
  for badfile in "$TMP_ROOT/large.md"; do
    docs_before=$(count fm_task_event)
    ft done doc-refusal "${DONE_FLAGS[@]}" --document "$badfile"
    must 'oversize document' 2 || return 1
    [ "$(count fm_task_event)" = "$docs_before" ] || return 1
  done
  for badfile in duplicate title-alone empty-title multiline-title; do
    docs_before=$(count fm_task_event)
    case "$badfile" in
      duplicate) ft done doc-refusal "${DONE_FLAGS[@]}" --document "$TMP_ROOT/report.md" --document "$TMP_ROOT/report.html" ;;
      title-alone) ft done doc-refusal "${DONE_FLAGS[@]}" --document-title title ;;
      empty-title) ft done doc-refusal "${DONE_FLAGS[@]}" --document "$TMP_ROOT/report.md" --document-title '' ;;
      multiline-title) ft done doc-refusal "${DONE_FLAGS[@]}" --document "$TMP_ROOT/report.md" --document-title $'two\nlines' ;;
    esac
    must 'document option refusal' 2 || return 1
    [ "$(count fm_task_event)" = "$docs_before" ] || return 1
  done
  reset_db
  export FM_HOME="$TMP_ROOT/terminal-home"
  mkdir -p "$FM_HOME/state"
  rm -f "$FM_HOME/state/tk10.status"
  local t=tk10 id seq child events dones before f field
  mk_running $t >/dev/null || { echo "setup: $ERR"; return 1; }
  log_reset
  ft "done" $t "${DONE_FLAGS[@]}" --pr-url https://example.com/pr/1 --head abc123
  must 'done' 0 || return 1
  grep -q '^done \[at=[0-9]*\]: Built it' "$FM_HOME/state/tk10.status" || { echo 'done did not write legacy status'; return 1; }
  seq=$(seq_of); [ -n "$seq" ] || { echo "no seq printed: $OUT"; return 1; }
  id=$(db fm_task_event | jq -r --argjson s "$seq" '.[] | select(.seq == $s and .kind == "done" and .taskId == "tk10") | .id')
  [ -n "$id" ] || { echo "no done event at seq $seq"; return 1; }
  child=$(db fm_event_done | jq -c --arg id "$id" '.[] | select(.fmTaskEventId == $id)')
  jq -e '.summary == "Built it" and .changedFiles == "bin/fm-task.sh" and .verification == "ran the tests" and .residualRisk == "none known" and .prUrl == "https://example.com/pr/1" and .head == "abc123" and (.rows | type == "string")' <<<"$child" >/dev/null \
    || { echo "stored done child: $child"; return 1; }
  [ "$(posts POST fm_task_event)" = 1 ] && [ "$(posts POST fm_event_done)" = 0 ] || { echo "the event and its child did not travel in one request"; return 1; }
  curl -s "$BASE/__x/log" | jq -e '[.[] | select(.method == "POST" and .path == "/api/fm_task_event")][0].body | (.done | length) == 1 and .seq == '"$seq" >/dev/null \
    || { echo "the event request does not carry the done child"; return 1; }
  [ "$(task_state $t)" = review ] || { echo "done did not move the task to review: $(task_state $t)"; return 1; }
  # TR32: a replayed stream and a fresh process do not enqueue twice.
  ft deliver tk10 --consumer test-firstmate
  must 'deliver events' 0 || return 1
  local deliveries
  deliveries=$(count fm_task_delivery)
  [ "$deliveries" -gt 0 ] || { echo 'no delivery rows'; return 1; }
  local wake_rows
  wake_rows=$(wc -l < "$FM_HOME/state/.wake-queue")
  ft deliver tk10 --consumer test-firstmate
  must 'replay delivery' 0 || return 1
  [ "$(wc -l < "$FM_HOME/state/.wake-queue")" = "$wake_rows" ] || { echo 'replay duplicated wake rows'; return 1; }
  [ "$(count fm_task_delivery)" = "$deliveries" ] || { echo 'replay duplicated deliveries'; return 1; }
  # Every ft invocation starts a fresh process: this is a delivery restart.
  ft comment tk10 --note 'event after delivery restart'
  must 'new event after restart' 0 || return 1
  ft deliver tk10 --consumer test-firstmate
  must 'deliver new event after restart' 0 || return 1
  [ "$(wc -l < "$FM_HOME/state/.wake-queue")" -eq "$((wake_rows + 1))" ] || { echo 'restart did not queue exactly the new event'; return 1; }
  # TR31: a status line cannot satisfy a terminal call; a heartbeat is not terminal.
  mk_running tk31 >/dev/null || return 1
  printf 'done: legacy-only\n' > "$FM_HOME/state/tk31.status"
  ft turn-end tk31 --turn first
  must 'missed terminal' 0 || return 1
  [[ "$OUT" = *ping-1 ]] || { echo "expected ping-1: $OUT"; return 1; }
  local violations
  violations=$(db fm_task_event | jq '[.[] | select(.taskId == "tk31" and .kind == "protocol_violation")] | length')
  ft turn-end tk31 --turn first
  must 'same turn replay' 0 || return 1
  [ "$(db fm_task_event | jq '[.[] | select(.taskId == "tk31" and .kind == "protocol_violation")] | length')" = "$violations" ] || return 1
  ft turn-end tk31 --turn second
  must 'second missed terminal' 0 || return 1
  ft turn-end tk31 --turn third
  must 'third missed terminal' 0 || return 1
  db fm_task | jq -e '.[] | select(.taskId == "tk31") | .blockKind == "capability" and .nextActor == "firstmate" and .state == "blocked"' >/dev/null || return 1
  ft turn-end tk31 --turn fourth
  must 'fourth missed terminal' 0 || return 1
  [ "$(db fm_task_event | jq '[.[] | select(.taskId == "tk31" and .kind == "blocked")] | length')" = 1 ] || { echo 'capability block repeated'; return 1; }
  # ask: one request, options stored as a JSON list, the task waits on its next actor
  mk_running tk10a >/dev/null; log_reset
  ft ask tk10a "${ASK_FLAGS[@]}"
  must 'ask' 0 || return 1
  id=$(db fm_task_event | jq -r --argjson s "$(seq_of)" '.[] | select(.seq == $s and .kind == "needs-decision") | .id')
  [ -n "$id" ] || { echo "no needs-decision event"; return 1; }
  db fm_event_question | jq -e --arg id "$id" '.[] | select(.fmTaskEventId == $id) | .question == "Which one?" and (.options | fromjson) == ["Option A","Option B"] and .recommendation == "Option A" and .why == "Both work; A is simpler"' >/dev/null \
    || { echo "stored question child wrong"; return 1; }
  [ "$(posts POST fm_event_question)" = 0 ] || { echo "question child was posted on its own"; return 1; }
  [ "$(task_state tk10a)" = blocked ] || { echo "ask did not block the task"; return 1; }
  # block: one request, the child carries kind, reason, next actor and until
  mk_running tk10b >/dev/null; log_reset
  ft block transient tk10b --reason 'waiting for the deploy' --next-actor firstmate --until 2026-10-26T08:00:00Z
  must 'block' 0 || return 1
  id=$(db fm_task_event | jq -r --argjson s "$(seq_of)" '.[] | select(.seq == $s and .kind == "blocked") | .id')
  [ -n "$id" ] || { echo "no blocked event"; return 1; }
  db fm_event_block | jq -e --arg id "$id" '.[] | select(.fmTaskEventId == $id) | .blockKind == "transient" and .reason == "waiting for the deploy" and .nextActor == "firstmate" and (.until | startswith("2026-10-26T08:00:00"))' >/dev/null \
    || { echo "stored block child wrong"; return 1; }
  [ "$(posts POST fm_event_block)" = 0 ] || { echo "block child was posted on its own"; return 1; }
  # a missing template field: the API's field is printed, nothing is stored, the task stays
  for field in summary changed-files verification residual-risk; do
    mk_running "tk10m-$field" >/dev/null
    events=$(count fm_task_event); dones=$(count fm_event_done)
    args=(); skip=0
    for f in "${DONE_FLAGS[@]}"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      if [ "$f" = "--$field" ]; then skip=1; continue; fi
      args+=("$f")
    done
    ft "done" "tk10m-$field" "${args[@]}"
    must "done without --$field" 4 || return 1
    case $(tr '[:upper:]' '[:lower:]' <<<"$ERR" | tr -d '-') in *"$(tr -d '-' <<<"$field")"*) ;; *) echo "the refusal does not name $field: $ERR"; return 1 ;; esac
    [ "$(count fm_task_event)" = "$events" ] && [ "$(count fm_event_done)" = "$dones" ] || { echo "a refused done stored rows (missing $field)"; return 1; }
    [ "$(task_state "tk10m-$field")" = running ] || { echo "a refused done moved the task"; return 1; }
  done
  mk_running tk10q >/dev/null; events=$(count fm_task_event)
  ft ask tk10q --option A --option B --recommendation A --why w
  must 'ask without --question' 4 || return 1
  case $ERR in *Question*) ;; *) echo "the refusal does not name Question: $ERR"; return 1 ;; esac
  mk_running tk10r >/dev/null
  ft block transient tk10r --next-actor firstmate
  must 'block without --reason' 4 || return 1
  case $ERR in *Reason*) ;; *) echo "the refusal does not name Reason: $ERR"; return 1 ;; esac
  before=$(count fm_event_block)
  ft block transient tk10r --reason r --next-actor firstmate --until not-a-date
  [ "$RC" -ne 0 ] && [ "$(count fm_event_block)" = "$before" ] || { echo "a bad --until was stored"; return 1; }
  ft ask tk10q --question q --option only --recommendation only --why w
  [ "$RC" -eq 5 ] || { echo "one option: exit $RC, want 5: $ERR"; return 1; }
  ft ask tk10q --question q --option 1 --option 2 --option 3 --option 4 --option 5 --option 6 --option 7 --recommendation 1 --why w
  [ "$RC" -eq 5 ] || { echo "seven options: exit $RC, want 5: $ERR"; return 1; }
  ft "done" tk10q --summary '' --changed-files f --verification v --residual-risk r
  if [ "$RC" -eq 0 ] || grep -q '^seq=' <<<"$OUT"; then echo "an empty --summary was stored"; return 1; fi
}

# TR11: 20 writers at once get consecutive seq values, a re-send returns the first event,
# a rival writer that takes the seq first is retried past, and a lost answer is not stored twice.
case_concurrent() {
  BIN=$1; reset_db
  local t=tk11 i first seqs want n
  local -a pids=()
  ft create $t --title t --kind ship >/dev/null || { echo "setup: $ERR"; return 1; }
  rm -f "$TMP_ROOT"/par.*
  for i in $(seq 1 20); do
    ( "$BIN/fm-task.sh" comment $t --note "c$i" > "$TMP_ROOT/par.$i" 2>&1; echo $? > "$TMP_ROOT/par.$i.rc" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  for i in $(seq 1 20); do
    [ "$(cat "$TMP_ROOT/par.$i.rc" 2>/dev/null)" = 0 ] || { echo "writer $i failed: $(cat "$TMP_ROOT/par.$i" 2>&1)"; return 1; }
  done
  seqs=$(db fm_task_event | jq -c '[.[].seq] | sort')
  want=$(jq -nc '[range(1; 22)]')
  [ "$seqs" = "$want" ] || { echo "seq values are not 1..21 with no gap: $seqs"; return 1; }
  [ "$(db fm_task_event | jq '[.[] | select(.kind == "comment")] | length')" = 20 ] || { echo "a comment was lost"; return 1; }
  [ "$(task_row $t | jq .lastSeq)" = 21 ] || { echo "the task row does not show seq 21: $(task_row $t)"; return 1; }
  # a re-send with the same key returns the first event
  ft comment $t --note once --key k-once
  must 'first send' 0 || return 1
  first=$(seq_of); n=$(count fm_task_event)
  ft comment $t --note once --key k-once
  must 're-send' 0 || return 1
  [ "$(seq_of)" = "$first" ] || { echo "the re-send returned seq $(seq_of), not $first"; return 1; }
  [ "$(count fm_task_event)" = "$n" ] || { echo "the re-send stored a second event"; return 1; }
  # a re-sent transition returns its first event even though the task has moved on
  mk_ready tk11s >/dev/null
  ft start tk11s --key k-start
  must 'start' 0 || return 1
  first=$(seq_of)
  ft start tk11s --key k-start
  must 're-sent start' 0 || return 1
  [ "$(seq_of)" = "$first" ] || { echo "the re-sent start returned seq $(seq_of), not $first"; return 1; }
  # a rival takes the next seq three times: the writer retries past it
  curl -s -X POST "$BASE/__x/rival?n=3" >/dev/null
  n=$(count fm_task_event)
  ft comment $t --note after --key k-after
  must 'after rivals' 0 || return 1
  [ "$(seq_of)" = $((n + 3 + 1)) ] || { echo "seq after three rivals is $(seq_of), want $((n + 4))"; return 1; }
  # the answer is lost before the event is stored: nothing stored, exit 3, a re-run stores it once
  n=$(count fm_task_event)
  curl -s -X POST "$BASE/__x/lose?mode=before&n=1" >/dev/null
  ft comment $t --note lost-before --key k-before
  must 'lost before' 3 || return 1
  [ "$(count fm_task_event)" = "$n" ] || { echo "an event was stored though the request was refused"; return 1; }
  ft comment $t --note lost-before --key k-before
  must 're-run after lost-before' 0 || return 1
  # the event is stored but the answer is lost: the lookup by key finds it, no second event
  n=$(count fm_task_event)
  curl -s -X POST "$BASE/__x/lose?mode=after&n=1" >/dev/null
  ft comment $t --note lost-after --key k-after-lost
  must 'lost after' 0 || return 1
  [ "$(count fm_task_event)" = $((n + 1)) ] || { echo "a lost answer stored the event $(( $(count fm_task_event) - n )) times"; return 1; }
  [ "$(seq_of)" = "$(db fm_task_event | jq '[.[] | select(.idempotencyKey == "k-after-lost")][0].seq')" ] || { echo "the printed seq is not the stored one"; return 1; }
}

# TR12: the Hermes transitions, every state x command pair, then the block-repeat and parent rules.
declare -A EXPECT
for s in triage todo ready running blocked review 'done' archived; do
  for c in assign start heartbeat 'done' ask block unblock approve changes archive comment; do EXPECT[$s:$c]=-; done
done
EXPECT[triage:assign]=ready;   EXPECT[triage:unblock]=ready;   EXPECT[triage:archive]=archived;   EXPECT[triage:comment]=triage
EXPECT[todo:assign]=todo;      EXPECT[todo:archive]=archived;  EXPECT[todo:comment]=todo
EXPECT[ready:assign]=ready;    EXPECT[ready:start]=running;    EXPECT[ready:archive]=archived;    EXPECT[ready:comment]=ready
EXPECT[running:heartbeat]=running; EXPECT[running:done]=review; EXPECT[running:ask]=blocked;      EXPECT[running:block]=blocked
EXPECT[running:comment]=running
EXPECT[blocked:unblock]=ready; EXPECT[blocked:archive]=archived; EXPECT[blocked:comment]=blocked
EXPECT[review:approve]='done';   EXPECT[review:changes]=ready;  EXPECT[review:archive]=archived;   EXPECT[review:comment]=review
EXPECT['done':archive]=archived; EXPECT['done':comment]='done'
EXPECT[archived:comment]=archived
CMDS='assign start heartbeat done ask block unblock approve changes archive comment'

put_in_state() {  # <task> <state>
  local t=$1
  case $2 in
    triage) ft create "$t" --title "T $t" --kind ship ;;
    todo) ft create "$t-parent" --title "P $t" --kind ship >/dev/null && ft create "$t" --title "T $t" --kind ship --after "$t-parent" ;;
    ready) mk_ready "$t" ;;
    running) mk_running "$t" ;;
    blocked) mk_running "$t" && ft block transient "$t" --reason waiting --next-actor firstmate ;;
    review) mk_running "$t" && ft "done" "$t" "${DONE_FLAGS[@]}" ;;
    done) mk_running "$t" && ft "done" "$t" "${DONE_FLAGS[@]}" && ft approve "$t" ;;
    archived) ft create "$t" --title "T $t" --kind ship && ft archive "$t" ;;
  esac
}
run_command() {  # <task> <command>
  case $2 in
    assign) ft assign "$1" --to worker-2 ;;
    done) ft "done" "$1" "${DONE_FLAGS[@]}" ;;
    ask) ft ask "$1" "${ASK_FLAGS[@]}" ;;
    block) ft block transient "$1" --reason waiting --next-actor firstmate ;;
    changes) ft changes "$1" --note 'fix the label' ;;
    comment) ft comment "$1" --note hi ;;
    *) ft "$2" "$1" ;;
  esac
}

case_transitions() {
  BIN=$1; reset_db
  local s c t want allowed events state listed n=0
  for s in triage todo ready running blocked review 'done' archived; do
    allowed=''
    for c in $CMDS; do [ "${EXPECT[$s:$c]}" = - ] || allowed="$allowed $c"; done
    for c in $CMDS; do
      n=$((n + 1)); t="tr12-$n"
      put_in_state "$t" "$s" >/dev/null || { echo "setup $s: $ERR"; return 1; }
      [ "$(task_state "$t")" = "$s" ] || { echo "setup left $t in $(task_state "$t"), want $s"; return 1; }
      events=$(count fm_task_event); want=${EXPECT[$s:$c]}
      run_command "$t" "$c"
      if [ "$want" = - ]; then
        must "$c from $s" 5 || return 1
        listed=$(sed -n 's/.*allowed from [a-z]*: *//p' <<<"$ERR" | head -1 | tr -d ',' | tr ' ' '\n' | sort | tr '\n' ' ')
        [ "$listed" = "$(tr ' ' '\n' <<<"$allowed" | sed '/^$/d' | sort | tr '\n' ' ')" ] || { echo "$c from $s lists [$listed], want [$allowed]: $ERR"; return 1; }
        [ "$(count fm_task_event)" = "$events" ] || { echo "a refused $c from $s stored an event"; return 1; }
        [ "$(task_state "$t")" = "$s" ] || { echo "a refused $c from $s moved the task"; return 1; }
      else
        must "$c from $s" 0 || return 1
        [ "$(task_state "$t")" = "$want" ] || { echo "$c from $s gave $(task_state "$t"), want $want"; return 1; }
      fi
    done
  done
  return 0
}

case_block_rules() {
  BIN=$1; reset_db
  local t=tk12b row i
  # a third block of one kind goes to triage; a different kind starts the count again
  mk_running $t >/dev/null
  for i in 1 2; do
    ft block transient $t --reason "try $i" --next-actor firstmate; must "block $i" 0 || return 1
    [ "$(task_state $t)" = blocked ] || { echo "block $i: $(task_state $t)"; return 1; }
    ft unblock $t; must "unblock $i" 0 || return 1
    ft start $t; must "start $i" 0 || return 1
  done
  ft block transient $t --reason 'try 3' --next-actor firstmate; must 'block 3' 0 || return 1
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = triage ] && [ "$(jq -r .nextActor <<<"$row")" = firstmate ] && [ "$(jq -r .blockRepeats <<<"$row")" = 3 ] \
    || { echo "the third block of one kind did not go to triage: $row"; return 1; }
  t=tk12c; mk_running $t >/dev/null
  ft block transient $t --reason a --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  ft block external $t --reason b --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  ft block transient $t --reason c --next-actor firstmate >/dev/null
  row=$(task_row $t)
  [ "$(jq -r .state <<<"$row")" = blocked ] && [ "$(jq -r .blockRepeats <<<"$row")" = 1 ] || { echo "a different kind did not start the count again: $row"; return 1; }
  # a done call ends the streak
  t=tk12d; mk_running $t >/dev/null
  ft block transient $t --reason a --next-actor firstmate >/dev/null; ft unblock $t >/dev/null; ft start $t >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  [ "$(task_row $t | jq -r .blockRepeats)" = 0 ] || { echo "done did not reset the block count: $(task_row $t)"; return 1; }
  return 0
}

case_parents() {
  BIN=$1; reset_db
  local p=tk12p c=tk12c1 events links
  mk_running $p >/dev/null; mk_running $c >/dev/null
  # a dependency waits in todo on an open parent
  ft block dependency $c --on $p --reason 'needs the parent' --next-actor worker
  must 'block dependency' 0 || return 1
  [ "$(task_state $c)" = todo ] || { echo "a dependency did not wait in todo: $(task_state $c)"; return 1; }
  db fm_task_link | jq -e --arg p $p --arg c $c 'any(.[]; .parentTaskId == $p and .childTaskId == $c)' >/dev/null || { echo "no link row for the dependency"; return 1; }
  ft start $c
  must 'start a waiting task' 5 || return 1
  ft assign $c --to worker-9
  must 'assign a waiting task' 0 || return 1
  [ "$(task_state $c)" = todo ] || { echo "assign took a waiting task out of todo: $(task_state $c)"; return 1; }
  # the parent finishing releases the child to ready, with an event
  ft "done" $p "${DONE_FLAGS[@]}" >/dev/null; ft approve $p >/dev/null
  [ "$(task_state $c)" = ready ] || { echo "the child was not released when the parent was approved: $(task_state $c)"; return 1; }
  db fm_task_event | jq -e --arg c $c 'any(.[]; .taskId == $c and .kind == "promoted")' >/dev/null || { echo "no promoted event for the released child"; return 1; }
  # a dependency needs an open parent that exists
  mk_running tk12c2 >/dev/null
  ft block dependency tk12c2 --on $p --reason r --next-actor worker
  must 'dependency on a done parent' 5 || return 1
  ft block dependency tk12c2 --on no-such-task --reason r --next-actor worker
  must 'dependency on a missing parent' 5 || return 1
  ft block dependency tk12c2 --reason r --next-actor worker
  [ "$RC" -ne 0 ] && [ "$(task_state tk12c2)" = running ] || { echo "a dependency with no --on was stored"; return 1; }
  # create --after an open parent waits; a link cannot make a cycle
  mk_running tk12p2 >/dev/null
  ft create tk12c3 --title c3 --kind ship --after tk12p2
  must 'create --after' 0 || return 1
  [ "$(task_state tk12c3)" = todo ] || { echo "create --after an open parent: $(task_state tk12c3)"; return 1; }
  ft create tk12a --title a --kind ship >/dev/null; ft create tk12b --title b --kind ship >/dev/null
  ft link tk12a tk12b
  must 'link' 0 || return 1
  ft link tk12b tk12a
  must 'link cycle' 5 || return 1
  case $ERR in *waits*) ;; *) echo "the cycle refusal does not say who waits on whom: $ERR"; return 1 ;; esac
  ft link tk12p2 tk12p2
  must 'link to itself' 5 || return 1
  links=$(count fm_task_link); events=$(count fm_task_event)
  ft link tk12p2 tk12c3
  must 'repeat link' 0 || return 1
  [ "$(count fm_task_link)" = "$links" ] && [ "$(count fm_task_event)" = "$events" ] || { echo "a repeat link stored again"; return 1; }
}

# The value lists the API cannot check.
case_value_lists() {
  BIN=$1; reset_db
  local before
  mk_running tk-vl >/dev/null
  before=$(count fm_task_event)
  ft block nonsense tk-vl --reason r --next-actor firstmate;      must 'block kind' 5 || return 1
  ft block transient tk-vl --reason r --next-actor nobody;        must 'next actor' 5 || return 1
  ft comment tk-vl --note x --role boss;                           must 'role' 5 || return 1
  ft create tk-vl2 --title t --kind weird;                         must 'task kind' 5 || return 1
  ft event tk-vl bogus --note x;                                   must 'event kind' 5 || return 1
  ft event tk-vl "done" --note x;                                  must 'terminal kind through event' 5 || return 1
  ft event tk-vl blocked --note x;                                 must 'blocked through event' 5 || return 1
  ft "done" tk-vl "${DONE_FLAGS[@]}" --next-actor owner;             must 'done next actor' 5 || return 1
  ft check tk-vl A1@- --status maybe;                              must 'check status' 5 || return 1
  ft create 'bad id!' --title t --kind ship;                       must 'task id' 2 || return 1
  ft create tk-vl --title t --kind ship;                           must 'duplicate task' 5 || return 1
  ft comment tk-vl --note x --key "$(printf 'k%.0s' $(seq 1 201))"; must 'long key' 2 || return 1
  ft create tk-long --title "$(printf 't%.0s' $(seq 1 301))" --kind ship; must 'long title' 5 || return 1
  ft bogus-command;                                                must 'unknown command' 2 || return 1
  ft comment tk-vl --nonsense 1;                                   must 'unknown flag' 2 || return 1
  [ "$(count fm_task_event)" = "$before" ] || { echo "a refused call stored an event"; return 1; }
  [ "$(task_row tk-long)" = '' ] || { echo "a refused create stored a task"; return 1; }
}

# TR13: one check row per scenario x width; a re-run adds, retires and resets.
case_rows() {
  BIN=$1; reset_db
  local t=tk13 checks n events row
  ft create $t --title t --kind ship >/dev/null
  use_issue v1
  ft rows $t "$ISSUE"
  must 'rows' 0 || return 1
  checks=$(db fm_task_check)
  [ "$(jq length <<<"$checks")" = 4 ] || { echo "want 4 rows (A1 x2 widths, A2, A3), got: $(jq -c '[.[] | .scenarioId + "@" + .width]' <<<"$checks")"; return 1; }
  jq -e 'all(.[]; .taskId == "tk13" and .status == "pending" and (.acceptanceDigest | test("^[0-9a-f]{64}$")))' <<<"$checks" >/dev/null || { echo "row fields: $(jq -c '.[0]' <<<"$checks")"; return 1; }
  jq -e '[.[] | select(.scenarioId == "A1") | .nextActor] == ["tester","tester"] and ([.[] | select(.scenarioId != "A1") | .nextActor] | unique) == ["worker"]' <<<"$checks" >/dev/null || { echo "next actors: $(jq -c '[.[] | [.scenarioId, .width, .nextActor]]' <<<"$checks")"; return 1; }
  jq -e '(.[] | select(.scenarioId == "A1" and .width == "1440")) | .line == "WHEN a user acts, THE page SHALL answer." and .surface == "user-visible" and .page == "home" and .proof == "click Save"' <<<"$checks" >/dev/null || { echo "row content wrong"; return 1; }
  # a re-run with the issue unchanged stores nothing and keeps results
  ft check $t A1@1440 --status pass --evidence 'tester record 1'; must 'check pass' 0 || return 1
  ft check $t A2@- --status pass --evidence 'unit run'; must 'check pass A2' 0 || return 1
  ft check $t A3@- --status fail --evidence 'red'; must 'check fail A3' 0 || return 1
  events=$(count fm_task_event)
  ft rows $t "$ISSUE"
  must 'rows again' 0 || return 1
  [ "$(count fm_task_event)" = "$events" ] && [ "$(count fm_task_check)" = 4 ] || { echo "an unchanged re-run stored something"; return 1; }
  db fm_task_check | jq -e '([.[] | .status] | sort) == ["fail","pass","pass","pending"]' >/dev/null || { echo "an unchanged re-run changed a result"; return 1; }
  # the issue is edited: A1's line changes (passed row resets), A2's proof changes (digest only), A4 is new
  use_issue v2
  ft rows $t "$ISSUE"
  must 'rows after edit' 0 || return 1
  checks=$(db fm_task_check)
  [ "$(jq length <<<"$checks")" = 5 ] || { echo "the new scenario was not added: $(jq length <<<"$checks") rows"; return 1; }
  row=$(jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")' <<<"$checks")
  [ "$(jq -r .status <<<"$row")" = pending ] && [ "$(jq -r .line <<<"$row")" = 'WHEN a user acts, THE page SHALL answer fast.' ] || { echo "a passed row with a new line was not reset: $row"; return 1; }
  row=$(jq -c '.[] | select(.scenarioId == "A2")' <<<"$checks")
  [ "$(jq -r .status <<<"$row")" = pending ] || { echo "a passed row with a new digest and the same line was not reset: $row"; return 1; }
  [ "$(jq -r '.[] | select(.scenarioId == "A3") | .status' <<<"$checks")" = fail ] || { echo "an unchanged row was touched"; return 1; }
  # a passed row stays passed when only another row changes
  ft check $t A2@- --status pass --evidence again >/dev/null
  # scenarios and widths leave the issue: their rows are retired, not deleted
  use_issue v3
  ft rows $t "$ISSUE"
  must 'rows after removal' 0 || return 1
  checks=$(db fm_task_check)
  [ "$(jq length <<<"$checks")" = 5 ] || { echo "a retired row was deleted"; return 1; }
  [ "$(jq -r '.[] | select(.scenarioId == "A4") | .status' <<<"$checks")" = retired ] && [ "$(jq -r '.[] | select(.scenarioId == "A1" and .width == "390") | .status' <<<"$checks")" = retired ] \
    || { echo "removed ids were not retired: $(jq -c '[.[] | [.scenarioId, .width, .status]]' <<<"$checks")"; return 1; }
  [ "$(jq -r '.[] | select(.scenarioId == "A2") | .status' <<<"$checks")" = pass ] || { echo "a passed row with no change was reset"; return 1; }
  # an id that comes back is open again
  use_issue v4
  ft rows $t "$ISSUE"
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A4") | .status')" = pending ] || { echo "a returned id stayed retired"; return 1; }
  [ "$(count fm_task_check)" = 5 ] || { echo "a returned id made a second row"; return 1; }
  # a refused issue stores nothing
  printf 'no scenarios here\n' > "$TMP_ROOT/issue.body"
  events=$(count fm_task_event)
  ft rows $t "$ISSUE"
  [ "$RC" -ne 0 ] && [ "$(count fm_task_event)" = "$events" ] || { echo "a refused issue was stored"; return 1; }
  # an open row blocks the approval
  mk_running tk13b >/dev/null; use_issue v1; ft rows tk13b "$ISSUE" >/dev/null
  ft "done" tk13b "${DONE_FLAGS[@]}" >/dev/null
  ft approve tk13b
  must 'approve with open rows' 5 || return 1
  [ "$(task_state tk13b)" = review ] || { echo "approve moved a task with open rows"; return 1; }
}

# TR15: an owner item is created with its check row's next actor; a refused item leaves the row alone.
case_owner() {
  BIN=$1; reset_db
  local t=tk15 row
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home page' --steps '1. open it' --data 'the probe row' --expected 'it loads'
  must 'owner-check without --url' 4 || return 1
  case $ERR in *Url*) ;; *) echo "the refusal does not name Url: $ERR"; return 1 ;; esac
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --data 'the probe row' --expected 'it loads'
  must 'owner-check without --steps' 4 || return 1
  case $ERR in *Steps*) ;; *) echo "the refusal does not name Steps: $ERR"; return 1 ;; esac
  [ "$(count fm_owner_check)" = 0 ] || { echo "a refused owner item was stored"; return 1; }
  row=$(db fm_task_check | jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")')
  [ "$(jq -r .nextActor <<<"$row")" = tester ] || { echo "a refused owner item changed the check row: $row"; return 1; }
  ft owner-check $t A1@1440 --page-title 'Home page' --url '' --steps '1. open it' --data d --expected e
  [ "$RC" -ne 0 ] && [ "$(count fm_owner_check)" = 0 ] || { echo "an empty --url was stored"; return 1; }
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data 'the probe row' --expected 'it loads'
  must 'owner-check' 0 || return 1
  db fm_owner_check | jq -e '.[0] | .taskId == "tk15" and .scenarioId == "A1" and .width == "1440" and .pageTitle == "Home page" and .url == "http://100.88.10.58:5001/#home" and .steps == "1. open it" and .data == "the probe row" and .expected == "it loads" and .status == "pending"' >/dev/null \
    || { echo "owner item wrong: $(db fm_owner_check | jq -c '.[0]')"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .nextActor')" = owner ] || { echo "the check row does not read owner"; return 1; }
  # no check row can read owner without its item
  ft check $t A2@- --status pending --next-actor owner
  must 'check next actor owner without an item' 5 || return 1
  ft check $t A1@1440 --status pending --next-actor owner
  must 'check next actor owner with its item' 0 || return 1
  ft owner-check $t NOPE@- --page-title p --url u --steps s --data d --expected e
  must 'owner-check for a missing row' 5 || return 1
  db fm_task_check | jq -e --argjson items "$(db fm_owner_check)" 'all(.[]; .nextActor != "owner" or (. as $r | any($items[]; .taskId == $r.taskId and .scenarioId == $r.scenarioId and .width == $r.width)))' >/dev/null \
    || { echo "a check row reads owner with no owner item"; return 1; }
  # the same call again finds its item and is not an error
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data 'the probe row' --expected 'it loads'
  must 'owner-check again' 0 || return 1
  [ "$(count fm_owner_check)" = 1 ] || { echo "owner-check again made a second item"; return 1; }
}

# TR14: resume gives the record in one screen; reproject rebuilds a damaged row from events.
case_resume() {
  BIN=$1; reset_db
  local t=tk14 lines events_shown row id before i
  ft create $t --title 'Resume me' --kind ship --repo example/repo --issue "$ISSUE" --surface internal >/dev/null
  use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft assign $t --to worker-1 >/dev/null; ft start $t >/dev/null
  ft heartbeat $t --note one >/dev/null; ft heartbeat $t --note two >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --pr-url https://example.com/pr/9 --head deadbeef >/dev/null
  ft resume $t
  must 'resume after done' 0 || return 1
  for want in 'state=review' 'assignee=worker-1' 'next=tester' 'Built it' 'bin/fm-task.sh' 'ran the tests' 'none known' 'https://example.com/pr/9' 'deadbeef' 'A1@1440' 'A2@-' 'A3@-'; do
    case $OUT in *"$want"*) ;; *) echo "resume lacks '$want':"; echo "$OUT"; return 1 ;; esac
  done
  lines=$(wc -l <<<"$OUT" | tr -d ' ')
  [ "$lines" -le 60 ] || { echo "resume is $lines lines, more than one screen"; return 1; }
  ft changes $t --note 'fix the label' >/dev/null; ft start $t >/dev/null
  ft ask $t "${ASK_FLAGS[@]}" >/dev/null
  for i in 1 2 3; do ft comment $t --note "extra $i" >/dev/null; done
  ft resume $t
  must 'resume after ask' 0 || return 1
  for want in 'state=blocked' 'needs-decision' 'Which one?' 'Option A' 'Option B' 'Both work; A is simpler'; do
    case $OUT in *"$want"*) ;; *) echo "resume lacks '$want':"; echo "$OUT"; return 1 ;; esac
  done
  case $OUT in *'Built it'*) echo "resume shows the older done call as the last terminal call"; return 1 ;; esac
  events_shown=$(sed -n '/^LAST 10 EVENTS/,$p' <<<"$OUT" | grep -c '^  #[0-9]')
  case $OUT in *'#1 created'*) echo "resume lists the first event, so it is not the last 10"; return 1 ;; esac
  [ "$events_shown" = 10 ] || { echo "resume lists $events_shown events, want the last 10:"; echo "$OUT"; return 1; }
  [ "$(wc -l <<<"$OUT" | tr -d ' ')" -le 60 ] || { echo "resume is more than one screen"; return 1; }
  case $OUT in *'open check rows'*|*'OPEN CHECK ROWS'*) ;; *) echo "resume has no open check rows section"; return 1 ;; esac
  # reproject: a damaged row is rebuilt from the events alone
  row=$(task_row $t); id=$(jq -r .id <<<"$row"); before=$(count fm_task_event)
  api -X PATCH "$BASE/api/fm_task/$id" -d '{"state":"archived","nextActor":"owner","title":"garbage","assignee":"nobody","lastSeq":0,"blockRepeats":9,"prUrl":"x"}' >/dev/null
  [ "$(task_state $t)" = archived ] || { echo "the test could not damage the row"; return 1; }
  ft reproject $t
  must 'reproject' 0 || return 1
  [ "$(jq -S 'del(.updatedAt)' <<<"$(task_row $t)")" = "$(jq -S 'del(.updatedAt)' <<<"$row")" ] || { echo "reproject did not restore the row:"; echo "want $row"; echo "got  $(task_row $t)"; return 1; }
  [ "$(count fm_task_event)" = "$before" ] || { echo "reproject wrote an event"; return 1; }
  # a task row that is gone is created again
  curl -s -X POST "$BASE/__x/drop/fm_task/$id" >/dev/null
  [ -z "$(task_row $t)" ] || { echo "the test could not drop the row"; return 1; }
  ft reproject $t
  must 'reproject a missing row' 0 || return 1
  [ "$(task_state $t)" = blocked ] || { echo "reproject did not create the missing row: $(task_row $t)"; return 1; }
  ft resume no-such-task
  must 'resume of a missing task' 5 || return 1
}

# A 5001 that does not answer is exit 3; a bad token file or token is refused with its reason.
case_connection() {
  BIN=$1; reset_db
  local cmd saved=$FM_TASK_BASE_URL
  export FM_TASK_BASE_URL=http://127.0.0.1:1
  for cmd in "show tk" "resume tk" "list" "create tk --title t --kind ship" "comment tk --note x"; do
    # shellcheck disable=SC2086 # the words are the arguments
    ft $cmd
    if [ "$RC" -ne 3 ] || grep -q '^seq=' <<<"$OUT"; then export FM_TASK_BASE_URL=$saved; echo "$cmd with no answer: exit $RC out=[$OUT] err=[$ERR]"; return 1; fi
  done
  export FM_TASK_BASE_URL=$saved
  FM_TASK_TOKEN_FILE="$TMP_ROOT/no-such-token" ft list
  must 'missing token file' 2 || return 1
  cp "$TMP_ROOT/token" "$TMP_ROOT/token.open"; chmod 644 "$TMP_ROOT/token.open"
  FM_TASK_TOKEN_FILE="$TMP_ROOT/token.open" ft list
  must 'token file open to others' 2 || return 1
  printf 'wrong\n' > "$TMP_ROOT/token.bad"; chmod 600 "$TMP_ROOT/token.bad"
  FM_TASK_TOKEN_FILE="$TMP_ROOT/token.bad" ft list
  must 'wrong token' 4 || return 1
  case $ERR in *401*) ;; *) echo "a wrong token does not show the HTTP status: $ERR"; return 1 ;; esac
  case $OUT$ERR in *"$TOKEN"*) echo "the token is printed"; return 1 ;; esac
  FM_TASK_AUTH=cookie ft list
  must 'cookie auth' 0 || return 1
}

# Reads, links, free events and images.
case_reads_and_images() {
  BIN=$1; reset_db
  local png="$TMP_ROOT/pixel.png" id
  printf '\x89PNG\r\n\x1a\n0000' > "$png"
  mk_ready tk-r1 >/dev/null; ft create tk-r2 --title second --kind scout >/dev/null
  ft show tk-r1 --json
  must 'show' 0 || return 1
  jq -e '.taskId == "tk-r1" and .state == "ready" and .assignee == "worker-1"' <<<"$OUT" >/dev/null || { echo "show --json: $OUT"; return 1; }
  ft list --state ready
  must 'list' 0 || return 1
  case $OUT in *tk-r1*) ;; *) echo "list lacks tk-r1: $OUT"; return 1 ;; esac
  case $OUT in *tk-r2*) echo "list --state ready shows a triage task"; return 1 ;; esac
  ft list --json
  jq -e 'length == 2' <<<"$OUT" >/dev/null || { echo "list --json: $OUT"; return 1; }
  ft event tk-r1 steer --note 'use the other base'
  must 'event steer' 0 || return 1
  db fm_task_event | jq -e 'any(.[]; .kind == "steer" and .taskId == "tk-r1")' >/dev/null || { echo "no steer event"; return 1; }
  log_reset
  ft comment tk-r1 --note 'see the picture' --image "$png" --image-label 'a pixel'
  must 'comment with an image' 0 || return 1
  id=$(db fm_task_event | jq -r --argjson s "$(seq_of)" '.[] | select(.seq == $s) | .id')
  db fm_event_image | jq -e --arg id "$id" '.[] | select(.fmTaskEventId == $id) | .label == "a pixel" and .mediaType == "image/png" and .position == 1 and (.content | length > 0)' >/dev/null || { echo "image child wrong"; return 1; }
  [ "$(posts POST fm_event_image)" = 0 ] || { echo "the image was posted on its own"; return 1; }
  ft comment tk-r1 --note x --image "$png"
  [ "$RC" -ne 0 ] || { echo "an image with no label was accepted"; return 1; }
  head -c 2200000 /dev/zero > "$TMP_ROOT/big.png"
  ft comment tk-r1 --note x --image "$TMP_ROOT/big.png" --image-label big
  [ "$RC" -ne 0 ] || { echo "an image over 2 MiB was accepted"; return 1; }
  ft heartbeat tk-r1
  must 'heartbeat from ready' 5 || return 1
  FM_TASK_ID=tk-r1 ft comment --note 'task from the environment'
  must 'task from FM_TASK_ID' 0 || return 1
}

# A re-sent check must not undo a newer result for the same row.
case_check_replay() {
  BIN=$1; reset_db
  local t=tk-replay row
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  st() { db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .status'; }
  ft check $t A2@- --status pass --key k-pass --evidence first; must 'pass' 0 || return 1
  ft check $t A2@- --status fail --key k-fail --evidence second; must 'fail' 0 || return 1
  ft check $t A2@- --status pass --key k-pass --evidence first
  must 'old pass re-sent' 0 || return 1
  [ "$(st)" = fail ] || { echo "a re-sent old pass overwrote the newer fail: $(st)"; return 1; }
  # the latest check re-sent still finishes its patch
  row=$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .id')
  api -X PATCH "$BASE/api/fm_task_check/$row" -d '{"status":"pending"}' >/dev/null
  ft check $t A2@- --status fail --key k-fail --evidence second
  must 'latest re-sent' 0 || return 1
  [ "$(st)" = fail ] || { echo "the latest check re-sent did not finish its patch: $(st)"; return 1; }
}

# When the last open row of a task in review passes, the task is routed to firstmate.
case_route() {
  BIN=$1; reset_db
  local t=tk-route row
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  [ "$(task_row $t | jq -r .nextActor)" = tester ] || { echo "done with user-visible rows open should wait on the tester: $(task_row $t)"; return 1; }
  ft check $t A1@1440 --status pass >/dev/null; ft check $t A1@390 --status pass >/dev/null; ft check $t A2@- --status pass >/dev/null
  [ "$(task_row $t | jq -r .nextActor)" = worker ] || { echo "with a worker row open the task should wait on the worker: $(task_row $t | jq -r .nextActor)"; return 1; }
  ft check $t A3@- --status pass
  must 'last pass' 0 || return 1
  [ "$(task_row $t | jq -r .nextActor)" = firstmate ] || { echo "the task stays with $(task_row $t | jq -r .nextActor) after the last row passed"; return 1; }
  ft list --actor firstmate
  case $OUT in *$t*) ;; *) echo "list --actor firstmate misses the task: $OUT"; return 1 ;; esac
  # the projection still equals the fold of the events
  row=$(task_row $t); ft reproject $t >/dev/null
  [ "$(task_row $t)" = "$row" ] || { echo "reproject changed the routed row"; return 1; }
}

# start refuses while a parent is open, even when the link was written but the child's todo event was not.
case_start_parent() {
  BIN=$1; reset_db
  mk_running tk-sp-parent >/dev/null; mk_ready tk-sp-child >/dev/null
  api -X POST "$BASE/api/fm_task_link" -d '{"parentTaskId":"tk-sp-parent","childTaskId":"tk-sp-child"}' >/dev/null
  [ "$(task_state tk-sp-child)" = ready ] || { echo "setup: the child is not ready"; return 1; }
  ft start tk-sp-child
  must 'start with an open parent' 5 || return 1
  case $ERR in *tk-sp-parent*) ;; *) echo "the refusal does not name the parent: $ERR"; return 1 ;; esac
  [ "$(task_state tk-sp-child)" = ready ] || { echo "start moved the child"; return 1; }
}

# approve needs rows for a user-visible task, passed on the head of the latest done.
case_approve_head() {
  BIN=$1; reset_db
  local t=tk-ah r
  ft create tk-ah0 --title t --kind ship --surface user-visible >/dev/null; ft assign tk-ah0 --to w >/dev/null; ft start tk-ah0 >/dev/null
  ft "done" tk-ah0 "${DONE_FLAGS[@]}" >/dev/null
  ft approve tk-ah0
  must 'approve a user-visible task with no rows' 5 || return 1
  case $ERR in *'no check rows'*) ;; *) echo "the refusal does not say the rows are missing: $ERR"; return 1 ;; esac
  [ "$(task_state tk-ah0)" = review ] || { echo "approve moved a user-visible task with no rows"; return 1; }
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass --head h1 >/dev/null; done
  ft approve $t
  must 'approve on the head of the done' 0 || return 1
  # new work: changes, a new done on head h2, and the old passes no longer count
  mk_running tk-ah2 >/dev/null; ft rows tk-ah2 "$ISSUE" >/dev/null
  ft "done" tk-ah2 "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check tk-ah2 $r --status pass --head h1 >/dev/null; done
  ft changes tk-ah2 --note again >/dev/null; ft start tk-ah2 >/dev/null
  ft "done" tk-ah2 "${DONE_FLAGS[@]}" --head h2 >/dev/null
  ft approve tk-ah2
  must 'approve on an older head' 5 || return 1
  case $ERR in *A1@1440*A1@390*|*A1@390*A1@1440*) ;; *) echo "the refusal does not name each stale row: $ERR"; return 1 ;; esac
  case $ERR in *A2@-*) echo "the refusal names an internal row: $ERR"; return 1 ;; esac
  for r in A1@1440 A1@390; do ft check tk-ah2 $r --status pass --head h2 >/dev/null; done
  ft approve tk-ah2
  must 'approve after the rows pass on h2' 0 || return 1
}

# A new owner item reopens a passed row, so approve cannot finish before the owner answers.
case_owner_pending() {
  BIN=$1; reset_db
  local t=tk-op
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e
  must 'owner-check on a passed row' 0 || return 1
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A1" and .width == "1440") | .status == "pending" and .nextActor == "owner"' >/dev/null \
    || { echo "the paired row is not pending with next actor owner: $(db fm_task_check | jq -c '.[] | select(.scenarioId == "A1" and .width == "1440")')"; return 1; }
  ft approve $t
  must 'approve before the owner answers' 5 || return 1
  [ "$(task_state $t)" = review ] || { echo "approve finished before the owner answered"; return 1; }
}

# rows on a closed task would reopen passed rows under a task that stays done.
case_rows_closed() {
  BIN=$1; reset_db
  local before
  use_issue v1
  ft create tk-rc1 --title t --kind ship >/dev/null; ft rows tk-rc1 "$ISSUE" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check tk-rc1 $r --status pass >/dev/null; done
  ft archive tk-rc1 >/dev/null
  use_issue v2; before=$(db fm_task_check | jq -c '[.[] | [.scenarioId, .width, .status]]')
  ft rows tk-rc1 "$ISSUE"
  must 'rows on an archived task' 5 || return 1
  case $ERR in *archived*) ;; *) echo "the refusal does not say why: $ERR"; return 1 ;; esac
  [ "$(db fm_task_check | jq -c '[.[] | [.scenarioId, .width, .status]]')" = "$before" ] || { echo "rows changed an archived task's rows"; return 1; }
  mk_running tk-rc2 >/dev/null; ft "done" tk-rc2 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-rc2 >/dev/null
  ft rows tk-rc2 "$ISSUE"
  must 'rows on a done task' 5 || return 1
  [ "$(count fm_task_check)" = 4 ] || { echo "rows added rows to a done task"; return 1; }
}

# check and owner-check refuse a task that is done or archived.
case_check_closed() {
  BIN=$1; reset_db
  local t=tk-cc r
  use_issue v1
  ft create $t --title t --kind ship >/dev/null; ft rows $t "$ISSUE" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  ft archive $t >/dev/null
  ft check $t A2@- --status fail
  must 'check on an archived task' 5 || return 1
  case $ERR in *archived*) ;; *) echo "the refusal does not say the task is archived: $ERR"; return 1 ;; esac
  ft owner-check $t A1@1440 --page-title p --url u --steps s --data d --expected e
  must 'owner-check on an archived task' 5 || return 1
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .status')" = pass ] || { echo "check changed a row of an archived task"; return 1; }
  [ "$(count fm_owner_check)" = 0 ] || { echo "owner-check stored an item for an archived task"; return 1; }
  mk_running tk-cc2 >/dev/null; ft "done" tk-cc2 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-cc2 >/dev/null
  ft check tk-cc2 A1@- --status pass
  must 'check on a done task' 5 || return 1
}

# check and owner-check refuse a retired row.
case_row_retired() {
  BIN=$1; reset_db
  local t=tk-rr
  ft create $t --title t --kind ship >/dev/null
  use_issue v2; ft rows $t "$ISSUE" >/dev/null
  use_issue v3; ft rows $t "$ISSUE" >/dev/null
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "390") | .status')" = retired ] || { echo "setup: A1@390 is not retired"; return 1; }
  ft check $t A1@390 --status pass
  must 'check on a retired row' 5 || return 1
  case $ERR in *retired*) ;; *) echo "the refusal does not say the row is retired: $ERR"; return 1 ;; esac
  ft owner-check $t A1@390 --page-title p --url u --steps s --data d --expected e
  must 'owner-check on a retired row' 5 || return 1
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "390") | .status')" = retired ] || { echo "the retired row changed"; return 1; }
  [ "$(count fm_owner_check)" = 0 ] || { echo "an owner item was stored for a retired row"; return 1; }
}

# done waits on the tester unless every user-visible pass is on the head of this done.
case_done_head() {
  BIN=$1; reset_db
  local t r
  local -A HEADOF=([tk-dh1]=h1 [tk-dh2]=h1)
  use_issue v1
  for t in tk-dh1 tk-dh2 tk-dh3; do
    mk_running $t >/dev/null; ft rows $t "$ISSUE" >/dev/null
    for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass ${HEADOF[$t]:+--head "${HEADOF[$t]}"} >/dev/null; done
  done
  ft "done" tk-dh1 "${DONE_FLAGS[@]}" --head h2 >/dev/null
  [ "$(task_row tk-dh1 | jq -r .nextActor)" = tester ] || { echo "a pass on h1 counted for a done on h2: $(task_row tk-dh1 | jq -c '{state,nextActor}')"; return 1; }
  ft "done" tk-dh2 "${DONE_FLAGS[@]}" --head h1 >/dev/null
  [ "$(task_row tk-dh2 | jq -r .nextActor)" = firstmate ] || { echo "a pass on the same head did not count: $(task_row tk-dh2 | jq -c '{state,nextActor}')"; return 1; }
  ft "done" tk-dh3 "${DONE_FLAGS[@]}" >/dev/null
  [ "$(task_row tk-dh3 | jq -r .nextActor)" = firstmate ] || { echo "passes with no head and a done with no head should match: $(task_row tk-dh3 | jq -c '{state,nextActor}')"; return 1; }
}

# Routing goes both ways: a row that opens again on a review task sends it back to that row's actor.
case_route_back() {
  BIN=$1; reset_db
  local t=tk-rb r row
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  na() { task_row $t | jq -r .nextActor; }
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  ft check $t A2@- --status fail >/dev/null
  [ "$(na)" = worker ] || { echo "a failed row did not send the task back to the worker: $(na)"; return 1; }
  ft check $t A2@- --status pass >/dev/null
  [ "$(na)" = firstmate ] || { echo "the row passed again but the task stays with $(na)"; return 1; }
  ft check $t A1@1440 --status pending >/dev/null
  [ "$(na)" = tester ] || { echo "a user-visible row open again did not send the task to the tester: $(na)"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .nextActor')" = tester ] || { echo "a reopened user-visible row reads another actor"; return 1; }
  ft check $t A1@1440 --status pass >/dev/null
  ft owner-check $t A1@390 --page-title p --url u --steps s --data d --expected e >/dev/null
  [ "$(na)" = owner ] || { echo "an owner item on a row did not send the task to the owner: $(na)"; return 1; }
  row=$(task_row $t); ft reproject $t >/dev/null
  [ "$(task_row $t)" = "$row" ] || { echo "reproject changed the routed row"; return 1; }
}

# A user-visible pass on another head than the latest done is still open: a later check does not undo the routing that done made.
case_route_stale() {
  BIN=$1; reset_db
  local t=tk-rst r
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  na() { task_row $t | jq -r .nextActor; }
  ft "done" $t "${DONE_FLAGS[@]}" --head h1 >/dev/null
  for r in A1@1440 A1@390; do ft check $t $r --status pass --head h1 >/dev/null; done
  for r in A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  ft changes $t --note again >/dev/null; ft start $t >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" --head h2 >/dev/null
  [ "$(na)" = tester ] || { echo "done on a new head did not wait on the tester: $(na)"; return 1; }
  ft check $t A3@- --status pass --evidence again
  must 'a later check' 0 || return 1
  [ "$(na)" = tester ] || { echo "a later check sent the task to $(na) while the passes sit on head h1: want tester"; return 1; }
  ft check $t A1@1440 --status pass --head h2 >/dev/null; ft check $t A1@390 --status pass --head h2 >/dev/null
  [ "$(na)" = firstmate ] || { echo "passes on the latest head left the task with $(na)"; return 1; }
}

# rows routes a task in review again after it adds, resets or retires rows.
case_rows_route() {
  BIN=$1; reset_db
  local t=tk-rr r
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  na() { task_row $t | jq -r .nextActor; }
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  [ "$(na)" = firstmate ] || { echo "setup: not routed to firstmate: $(na)"; return 1; }
  use_issue v2; ft rows $t "$ISSUE"
  must 'rows with new and reset rows' 0 || return 1
  [ "$(na)" = worker ] || { echo "rows added and reset rows but the task waits on $(na); want worker"; return 1; }
  for r in A1@1440 A1@390 A2@-; do ft check $t $r --status pass >/dev/null; done
  [ "$(na)" = worker ] || { echo "setup: A4 is open but the task waits on $(na)"; return 1; }
  use_issue v5; ft rows $t "$ISSUE"
  must 'rows retiring the open row' 0 || return 1
  [ "$(na)" = firstmate ] || { echo "rows retired the open row but the task waits on $(na); want firstmate"; return 1; }
}

# A re-sent owner-check key finishes its own call and cannot undo a newer verdict.
case_owner_replay() {
  BIN=$1; reset_db
  local t=tk-ore id events
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  OC=(owner-check "$t" A1@1440 --page-title Home --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e)
  rowst() { db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor'; }
  ft "${OC[@]}" --key k-oc >/dev/null; must 'owner-check' 0 || return 1
  id=$(db fm_owner_check | jq -r '.[0].id')
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pass --key k-verdict >/dev/null
  events=$(count fm_task_event)
  ft "${OC[@]}" --key k-oc; must 'owner-check re-sent' 0 || return 1
  [ "$(rowst)" = pass/firstmate ] || { echo "a re-sent owner-check undid the newer verdict: $(rowst)"; return 1; }
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pass ] || { echo "a re-sent owner-check reopened the answered item"; return 1; }
  [ "$(count fm_task_event)" = "$events" ] || { echo "a re-sent owner-check stored an event"; return 1; }
  # the same key with another page or another row is another call
  ft owner-check $t A1@1440 --page-title Other --url 'http://100.88.10.58:5001/#home' --steps s --data d --expected e --key k-oc
  must 'owner-check re-sent with another page title' 5 || return 1
  ft "${OC[@]/A1@1440/A1@390}" --key k-oc
  must 'owner-check re-sent for another row' 5 || return 1
}

# A new result with no --head or --evidence keeps no head or evidence of an older one.
case_check_nulls() {
  BIN=$1; reset_db
  local t=tk-cn
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  rowv() { db fm_task_check | jq -c '.[] | select(.scenarioId == "A2") | {status, evidence, head}'; }
  ft check $t A2@- --status pass --evidence first --head h1 >/dev/null
  [ "$(rowv)" = '{"status":"pass","evidence":"first","head":"h1"}' ] || { echo "setup: $(rowv)"; return 1; }
  ft check $t A2@- --status pending >/dev/null
  ft check $t A2@- --status pass; must 'a pass with no head' 0 || return 1
  [ "$(rowv)" = '{"status":"pass","evidence":null,"head":null}' ] || { echo "a new pass kept the older evidence or head: $(rowv)"; return 1; }
}

# A check cannot be stored behind an approval that closed the task in between, and approve judges the rows from the newest check events.
case_check_close() {
  BIN=$1; reset_db
  local t=tk-cc r pid
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  # the check has read the open task and waits for its row; the approval lands first
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=800&n=1&verb=list" >/dev/null
  ( "$BIN/fm-task.sh" check $t A2@- --status fail --evidence late > "$TMP_ROOT/cc.out" 2>&1; echo $? > "$TMP_ROOT/cc.rc" ) &
  pid=$!
  sleep 0.3
  ft approve $t; must 'approve' 0 || return 1
  wait $pid
  [ "$(cat "$TMP_ROOT/cc.rc")" = 5 ] || { echo "the check behind the approval exited $(cat "$TMP_ROOT/cc.rc"), want 5: $(cat "$TMP_ROOT/cc.out")"; return 1; }
  db fm_task_event | jq -e '[.[] | select(.kind == "check" and (.body | fromjson | .values.evidence == "late"))] | length == 0' >/dev/null \
    || { echo "a check event was stored after the task closed"; return 1; }
  [ "$(task_state $t)" = "done" ] || { echo "the task is $(task_state $t), want done"; return 1; }
}

# approve judges a row by its newest check event, also while that event's patch is still on its way.
case_approve_newest() {
  BIN=$1; reset_db
  local t=tk-an r pid
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=900&n=1" >/dev/null
  ( "$BIN/fm-task.sh" check $t A2@- --status fail --evidence late > "$TMP_ROOT/an.out" 2>&1 ) &
  pid=$!
  sleep 0.5
  ft approve $t
  must 'approve while a failed check is on its way' 5 || return 1
  wait $pid
  [ "$(task_state $t)" = review ] || { echo "the task is $(task_state $t) after a refused approve, want review"; return 1; }
  ft approve $t; must 'approve' 5 || return 1
}

# owner-check on a row that already has an item needs --url and --steps too, and changes nothing without them.
case_owner_update() {
  BIN=$1; reset_db
  local t=tk-ou events item
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft owner-check $t A1@1440 --page-title 'Home page' --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e >/dev/null
  events=$(count fm_task_event); item=$(db fm_owner_check | jq -S -c .)
  ft owner-check $t A1@1440 --page-title 'New title' --steps '1. open it' --data d --expected e
  must 'update without --url' 5 || return 1
  case $ERR in *url*) ;; *) echo "the refusal does not name url: $ERR"; return 1 ;; esac
  ft owner-check $t A1@1440 --page-title 'New title' --url 'http://100.88.10.58:5001/#home' --data d --expected e
  must 'update without --steps' 5 || return 1
  case $ERR in *steps*) ;; *) echo "the refusal does not name steps: $ERR"; return 1 ;; esac
  [ "$(count fm_task_event)" = "$events" ] && [ "$(db fm_owner_check | jq -S -c .)" = "$item" ] || { echo "a refused update changed the record"; return 1; }
  ft owner-check $t A1@1440 --page-title 'New title' --url 'http://100.88.10.58:5001/#home2' --steps '2. open it' --data d --expected e
  must 'update with --url and --steps' 0 || return 1
  db fm_owner_check | jq -e '.[0] | .pageTitle == "New title" and .url == "http://100.88.10.58:5001/#home2" and .steps == "2. open it"' >/dev/null || { echo "the update was not stored"; return 1; }
}

# An owner-check cannot be stored behind an approval that closed the task in between.
case_owner_close() {
  BIN=$1; reset_db
  local t=tk-oc r pid
  mk_running $t >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft "done" $t "${DONE_FLAGS[@]}" >/dev/null
  for r in A1@1440 A1@390 A2@- A3@-; do ft check $t $r --status pass >/dev/null; done
  # the owner-check has read the open task and waits for its row; the approval lands first
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=800&n=1&verb=list" >/dev/null
  ( "$BIN/fm-task.sh" owner-check $t A2@- --page-title p --url u --steps s --data d --expected e > "$TMP_ROOT/oc.out" 2>&1; echo $? > "$TMP_ROOT/oc.rc" ) &
  pid=$!
  sleep 0.3
  ft approve $t; must 'approve' 0 || return 1
  wait $pid
  [ "$(cat "$TMP_ROOT/oc.rc")" = 5 ] || { echo "the owner-check behind the approval exited $(cat "$TMP_ROOT/oc.rc"), want 5: $(cat "$TMP_ROOT/oc.out")"; return 1; }
  db fm_task_event | jq -e '[.[] | select(.kind == "owner-check")] | length == 0' >/dev/null || { echo "an owner-check event was stored after the task closed"; return 1; }
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .status + "/" + .nextActor')" = pass/firstmate ] || { echo "the owner-check changed a row of the closed task"; return 1; }
}

# A re-sent key carries the values of its first event; a retry with other values is refused.
case_check_values() {
  BIN=$1; reset_db
  local t=tk-cv ev row
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  ft check $t A2@- --status pass --key k-v --evidence e1 --head h1
  must 'first check' 0 || return 1
  ft check $t A2@- --status pass --key k-v --evidence e1 --head h1
  must 'identical re-send' 0 || return 1
  for ev in "--status fail --evidence e1 --head h1" "--status pass --evidence e2 --head h1" "--status pass --evidence e1 --head h2"; do
    # shellcheck disable=SC2086 # the words are the arguments
    ft check $t A2@- --key k-v $ev
    must "re-send with other values ($ev)" 5 || return 1
  done
  ft check $t A3@- --status pass --key k-v --evidence e1 --head h1
  must 're-send on another row' 5 || return 1
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A2") | .status == "pass" and .evidence == "e1" and .head == "h1"' >/dev/null || { echo "a refused re-send changed the row"; return 1; }
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A3") | .status == "pending"' >/dev/null || { echo "a refused re-send changed another row"; return 1; }
  # the row takes the values stored in its newest event, even when the row was damaged
  row=$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A2") | .id')
  api -X PATCH "$BASE/api/fm_task_check/$row" -d '{"status":"fail","evidence":"damaged"}' >/dev/null
  ft check $t A2@- --status pass --key k-v --evidence e1 --head h1
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A2") | .status == "pass" and .evidence == "e1"' >/dev/null || { echo "the re-send did not restore the stored values"; return 1; }
}

# Parallel checks on one row leave the values of the newest check event on the row.
case_check_parallel() {
  BIN=$1; reset_db
  local t=tk-cp round i st newest row pids
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  # the first call's patch is held until a second call has finished: the newest event still wins
  curl -s -X POST "$BASE/__x/delay/fm_task_check?ms=700&n=1" >/dev/null
  ( "$BIN/fm-task.sh" check $t A2@- --status pass --evidence slow --head hs > "$TMP_ROOT/cp.slow" 2>&1 ) &
  pids=($!)
  sleep 0.3
  ft check $t A2@- --status fail --evidence fast --head hf
  must 'the fast check' 0 || return 1
  wait "${pids[@]}"
  db fm_task_check | jq -e '.[] | select(.scenarioId == "A2") | .status == "fail" and .evidence == "fast" and .head == "hf"' >/dev/null \
    || { echo "a slow older check overwrote the newest: $(db fm_task_check | jq -c '.[] | select(.scenarioId == "A2") | {status, evidence, head}')"; return 1; }
  for round in 1 2 3 4 5 6; do
    pids=()
    for i in 1 2 3 4 5 6 7 8; do
      st=pass; [ $((i % 2)) = 0 ] && st=fail
      ( "$BIN/fm-task.sh" check $t A2@- --status $st --evidence "r$round-$i" --head "h$round-$i" > "$TMP_ROOT/cp.$i" 2>&1 ) &
      pids+=($!)
    done
    wait "${pids[@]}"
    newest=$(db fm_task_event | jq -c '[.[] | select(.kind == "check" and (.body | fromjson | .row == "A2@-"))] | max_by(.seq) | .body | fromjson | .values')
    row=$(db fm_task_check | jq -c '.[] | select(.scenarioId == "A2") | {status, evidence, head}')
    [ "$(jq -c '{status, evidence, head}' <<<"$newest")" = "$row" ] || { echo "round $round: the row holds $row, the newest event stored $newest"; return 1; }
  done
}

# owner-check with unchanged fields changes nothing; a row reset to pending reopens its item.
case_owner_repeat() {
  BIN=$1; reset_db
  local t=tk-or events row_before item_before id
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  OC=(owner-check "$t" A1@1440 --page-title Home --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e)
  ft "${OC[@]}"; must 'owner-check' 0 || return 1
  events=$(count fm_task_event); item_before=$(db fm_owner_check | jq -S -c .); row_before=$(db fm_task_check | jq -S -c .)
  ft "${OC[@]}"; must 'owner-check repeated' 0 || return 1
  [ "$(count fm_task_event)" = "$events" ] || { echo "a repeat stored an event"; return 1; }
  [ "$(db fm_owner_check | jq -S -c .)" = "$item_before" ] || { echo "a repeat changed the item"; return 1; }
  [ "$(db fm_task_check | jq -S -c .)" = "$row_before" ] || { echo "a repeat changed the rows"; return 1; }
  # the owner answered; the row is set to pending again by hand: the item is pending again too
  id=$(db fm_owner_check | jq -r '.[0].id')
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pending --next-actor owner >/dev/null
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pending ] || { echo "a row set to pending left its item at $(db fm_owner_check | jq -r '.[0].status')"; return 1; }
  # the row passed meanwhile; the same owner-check opens both again
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pass >/dev/null
  ft "${OC[@]}"; must 'owner-check after the row passed' 0 || return 1
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pending ] && [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor')" = pending/owner ] \
    || { echo "owner-check did not open the row and the item again"; return 1; }
  # a row reset by the issue edit reopens its item
  api -X PATCH "$BASE/api/fm_owner_check/$id" -d '{"status":"pass"}' >/dev/null
  ft check $t A1@1440 --status pass >/dev/null
  use_issue v2; ft rows $t "$ISSUE" >/dev/null
  [ "$(db fm_owner_check | jq -r '.[0].status')" = pending ] || { echo "rows reset the row but left the item at $(db fm_owner_check | jq -r '.[0].status')"; return 1; }
}

# A row reset by rows, or reopened by owner-check, supersedes its older check events: a re-sent old key cannot restore the old result.
case_reset_supersedes() {
  BIN=$1; reset_db
  local t=tk-rsup
  ft create $t --title t --kind ship >/dev/null; use_issue v1; ft rows $t "$ISSUE" >/dev/null
  st() { db fm_task_check | jq -r --arg s "$1" '.[] | select(.scenarioId == $s) | .status + "/" + .nextActor'; }
  ft check $t A2@- --status pass --key k-old --evidence first >/dev/null
  use_issue v2; ft rows $t "$ISSUE" >/dev/null
  [ "$(st A2)" = pending/worker ] || { echo "rows did not reset A2: $(st A2)"; return 1; }
  ft check $t A2@- --status pass --key k-old --evidence first
  must 'old pass re-sent after the reset' 0 || return 1
  [ "$(st A2)" = pending/worker ] || { echo "a re-sent old pass restored a reset row: $(st A2)"; return 1; }
  ft check $t A1@1440 --status pass --key k-a1 >/dev/null
  ft owner-check $t A1@1440 --page-title Home --url 'http://100.88.10.58:5001/#home' --steps '1. open it' --data d --expected e >/dev/null
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor')" = pending/owner ] || { echo "owner-check did not reopen A1@1440"; return 1; }
  ft check $t A1@1440 --status pass --key k-a1
  must 'old pass re-sent after owner-check' 0 || return 1
  [ "$(db fm_task_check | jq -r '.[] | select(.scenarioId == "A1" and .width == "1440") | .status + "/" + .nextActor')" = pending/owner ] \
    || { echo "a re-sent old pass restored a row the owner was asked about"; return 1; }
}

# A triage child linked to an open parent still reaches ready after assign once the parent has closed.
case_link_triage() {
  BIN=$1; reset_db
  mk_running tk-lt-p1 >/dev/null; ft create tk-lt-c1 --title c1 --kind ship >/dev/null
  ft link tk-lt-p1 tk-lt-c1; must 'link a triage child' 0 || return 1
  [ "$(task_state tk-lt-c1)" = triage ] || { echo "linking moved the triage child to $(task_state tk-lt-c1)"; return 1; }
  ft "done" tk-lt-p1 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-lt-p1 >/dev/null
  [ "$(task_state tk-lt-c1)" = triage ] || { echo "closing the parent moved the triage child to $(task_state tk-lt-c1)"; return 1; }
  ft assign tk-lt-c1 --to w; must 'assign after the parent closed' 0 || return 1
  [ "$(task_state tk-lt-c1)" = ready ] || { echo "assign after the parent closed gave $(task_state tk-lt-c1), want ready"; return 1; }
  ft start tk-lt-c1; must 'start the released child' 0 || return 1
  # assign while the parent is still open waits in todo, and the parent closing releases it
  mk_running tk-lt-p2 >/dev/null; ft create tk-lt-c2 --title c2 --kind ship >/dev/null
  ft link tk-lt-p2 tk-lt-c2 >/dev/null; ft assign tk-lt-c2 --to w >/dev/null
  [ "$(task_state tk-lt-c2)" = todo ] || { echo "assign with an open parent gave $(task_state tk-lt-c2), want todo"; return 1; }
  ft "done" tk-lt-p2 "${DONE_FLAGS[@]}" >/dev/null; ft approve tk-lt-p2 >/dev/null
  [ "$(task_state tk-lt-c2)" = ready ] || { echo "the parent closing left the child in $(task_state tk-lt-c2)"; return 1; }
}

CASES=${FM_TASK_CASES:-"terminal concurrent transitions block_rules parents value_lists rows owner resume connection reads_and_images check_replay route start_parent approve_head owner_pending rows_closed check_closed row_retired done_head route_back check_values check_parallel owner_repeat link_triage reset_supersedes route_stale rows_route owner_replay check_nulls check_close approve_newest owner_update owner_close"}

# ---- real command -------------------------------------------------------------------

for c in $CASES; do
  out=$(case_"$c" "$ROOT/bin" 2>&1) || fail "case $c failed on the real command: $out"
  pass "fm-task $c"
done

# FM_TASK_CASES="a b" runs just those cases and skips the mutation proofs.
[ -z "${FM_TASK_CASES:-}" ] || exit 0

# ---- mutation proofs: remove one guard, the case guarding it goes red -----------------------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
for f in fm-task.sh fm-task-lib.mjs fm-acceptance.mjs; do cp "$ROOT/bin/$f" "$TMP_ROOT/$f.orig"; done
cp "$TMP_ROOT/fm-acceptance.mjs.orig" "$MBIN/fm-acceptance.mjs"
cp "$TMP_ROOT/fm-task.sh.orig" "$MBIN/fm-task.sh"
chmod +x "$MBIN/fm-task.sh"
LIB="$MBIN/fm-task-lib.mjs"

mutate() {  # <label> <case> <exact source text> <replacement>
  cp "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB"
  S="$3" R="$4" perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$LIB"
  cmp -s "$TMP_ROOT/fm-task-lib.mjs.orig" "$LIB" && fail "mutation '$1' changed nothing"
  if out=$(case_"$2" "$MBIN" 2>&1); then
    fail "removing the guard '$1' left case $2 green"
  fi
  pass "guard '$1' is needed: case $2 goes red without it"
}

mutate 'the event and its child travel in one request' terminal 'Object.assign(body, spec.children || {});' ';'
mutate 'an empty value is refused' terminal "if (value === '') throw usage" 'if (false) throw usage'
mutate 'the option count is checked' terminal 'if (options.length < 2 || options.length > 6)' 'if (false)'
mutate 'a seq taken by another writer is retried' concurrent 'if (res.status === 409) {' 'if (false) {'
mutate 'a re-send finds its first event before the rules run' concurrent 'if (prior) {' 'if (false) {'
mutate 'the key makes a re-send return the first event' concurrent 'args.flags.key ||' ''
mutate 'a lost answer is looked up by its key' concurrent 'if (found) return { event: found, replayed: false };' 'if (false) return { event: found, replayed: false };'
mutate 'a refused move is refused' transitions 'if (!TRANSITIONS[command].includes(task.state)) {' 'if (false) {'
mutate 'the third block of one kind goes to triage' block_rules "const triage = kind !== 'dependency' && repeats >= 3;" 'const triage = false;'
mutate 'a different kind starts the count again' block_rules 'task.blockKind === kind ? task.blockRepeats + 1 : 1' 'task.blockRepeats + 1'
mutate 'a dependency waits in todo on an open parent' parents "state: waiting ? 'todo' : 'ready'" "state: 'ready'"
mutate 'a closed parent releases its children' parents 'if (!child || child.state !== '"'"'todo'"'"' || (await openParents(link.childTaskId)).length) continue;' 'continue;'
mutate 'a dependency needs an open parent' parents 'if (CLOSED.includes(parent.state)) throw rule(`parent ${f.on}' 'if (false) throw rule(`parent ${f.on}'
mutate 'a link cannot make a cycle' parents 'if (!existing && (await wouldCycle(parent, child)))' 'if (false)'
mutate 'a value outside its list is refused' value_lists 'if (!list.includes(value))' 'if (false)'
mutate 'a changed digest resets a passed row' rows 'row.line !== want.line || row.acceptanceDigest !== want.acceptanceDigest' 'row.line !== want.line'
mutate 'a changed line resets a passed row' rows "changed && row.status === 'pass'" 'false'
mutate 'a removed id is retired' rows "if (wanted.has(key) || row.status === 'retired') continue;" 'continue;'
mutate 'an issue with no template is refused' rows ", 'parse', issue, '--strict']" ", 'parse', issue]"
mutate 'open rows block the approval' rows 'if (open.length) throw rule(`approve is refused' 'if (false) throw rule(`approve is refused'
mutate 'a check row cannot read owner without its item' owner 'if (nextActor === '"'"'owner'"'"' && !(await ownerItem(taskId, target)))' 'if (false)'
mutate 'the owner item and the owner row go together' owner "ok(await http('POST', '/api/fm_owner_check', item), 'the owner item');" "await http('POST', '/api/fm_owner_check', item);"
mutate 'resume lists the last 10 events' resume 'events.slice(-10)' 'events'
mutate 'resume gives the last terminal call with its fields' resume 'for (const field of TEMPLATE_FIELDS[last.kind])' 'for (const field of [])'
mutate 'reproject rebuilds a damaged row' resume 'if (diff.length) {' 'if (false) {'
mutate 'an API that does not answer is exit 3' connection 'throw new Fail(3, `${method} ${pathname}: no answer' 'throw new Fail(1, `${method} ${pathname}: no answer'
mutate 'the last passed row routes the task to firstmate' route 'if (!(await needed())) return;' 'return;'
mutate 'start waits for an open parent' start_parent 'if (parents.length) throw rule(`start is refused' 'if (false) throw rule(`start is refused'
mutate 'a user-visible task needs check rows to be approved' approve_head 'if (task.surface === '"'"'user-visible'"'"' && !visible.length)' 'if (false)'
mutate 'a pass counts only on the head of the latest done' approve_head 'if (stale.length) throw rule(`approve is refused' 'if (false) throw rule(`approve is refused'
mutate 'an owner item reopens its row' owner_pending "values: { status: 'pending', nextActor: 'owner'" "values: { status: row.status, nextActor: 'owner'"
mutate 'rows are refused on a closed task' rows_closed 'if (CLOSED.includes(task.state)) throw rule(`rows is refused' 'if (false) throw rule(`rows is refused'
mutate 'check and owner-check refuse a closed task' check_closed 'if (CLOSED.includes(task.state)) throw rule(`${command} is refused' 'if (false) throw rule(`${command} is refused'
mutate 'a retired row takes no check' row_retired "if (row.status === 'retired') throw rule(\`check row" "if (false) throw rule(\`check row"
mutate 'a pass counts for the head it was taken on' done_head "&& !(r.status === 'pass' && (r.head ?? null) === (f.head ?? null))" "&& r.status !== 'pass'"
mutate 'a row that opens again sends the task back' route_back "return ['worker', 'tester', 'owner'].find((a) => waiting.includes(a)) ?? 'firstmate';" "return 'firstmate';"
mutate 'a re-sent key with other values is refused' check_values 'if (differs.length) throw rule(`the key' 'if (false) throw rule(`the key'
mutate 'a re-sent check cannot undo a newer result' check_replay "const newest = rowEvent(await taskEvents(taskId), row);" "const newest = rowEvent((await taskEvents(taskId)).filter((e) => bodyOf(e).values?.status === 'pass'), row);"
mutate 'the newest check event wins over a slower older call' check_parallel 'if (!v || newest.seq === applied) return;' 'if (!v || applied) return;'
mutate 'an owner-check that changes nothing writes nothing' owner_repeat "row.nextActor === 'owner' && row.status === 'pending') {" "false) {"
mutate 'a row set to pending reopens its item' owner_repeat "if (v.status === 'pending') await reopenItem(taskId" "if (false) await reopenItem(taskId"
mutate 'a row reset by rows supersedes its older check events' reset_supersedes "await resetEvent(key, actorFor(want.surface));
      ok(await http('PATCH', \`/api/fm_task_check/\${row.id}\`, { ...text, ...fresh, nextActor: actorFor(want.surface) }), \`reset the check row" "ok(await http('PATCH', \`/api/fm_task_check/\${row.id}\`, { ...text, ...fresh, nextActor: actorFor(want.surface) }), \`reset the check row"
mutate 'an owner-check supersedes the older check events of its row' reset_supersedes "extra: { row: rowKey(row), values: { status: 'pending', nextActor: 'owner'" "extra: { row: 'none', values: { status: 'pending', nextActor: 'owner'"
mutate 'a pass on another head than the latest done is still open for routing' route_stale "(passedOnOtherHead(r, head) ? 'tester' : r.nextActor)" "(r.nextActor)"
mutate 'rows routes a task in review again' rows_route "set: sets }), () => routeReview(taskId, who));" "set: sets }));"
mutate 'a re-sent owner-check does not write its item again' owner_replay "const existing = prior ? null : await ownerItem(taskId, target);" "const existing = await ownerItem(taskId, target);"
mutate 'a re-sent owner-check key with another call is refused' owner_replay "if (prior && (prior.taskId !== taskId ||" "if (false && (prior.taskId !== taskId ||"
mutate 'a new result clears the head and evidence of an older one' check_nulls "evidence: v.evidence ?? null, head: v.head ?? null };" "...(v.evidence ? { evidence: v.evidence } : {}), ...(v.head ? { head: v.head } : {}) };"
mutate 'a check on a task that closed meanwhile is refused' check_close "if (CLOSED.includes(task.state)) throw rule(\`check is refused:" "if (false) throw rule(\`check is refused:"
mutate 'approve judges a row by its newest check event' approve_newest "return v ? { ...r, status: v.status," "return false ? { ...r, status: v.status,"
mutate 'an owner-check update needs --url and --steps' owner_update "if (missing.length) throw rule(" "if (false) throw rule("
mutate 'an owner-check on a task that closed meanwhile is refused' owner_close "if (CLOSED.includes(task.state)) throw rule(\`owner-check is refused:" "if (false) throw rule(\`owner-check is refused:"
mutate 'done document is carried by the event deep insert' terminal '...(documents ? { documents: [documents] } : {})' '...{}'
mutate 'document byte limit is checked before writing' terminal 'bytes.length > 2 * 1024 * 1024' 'false'
mutate 'document UTF-8 is strict' terminal 'fatal: true, ignoreBOM: true' 'fatal: false, ignoreBOM: true'
mutate 'document title requires a document' terminal "if (f['document-title'] !== undefined) throw usage" 'if (false) throw usage'
mutate 'capability block is emitted once' terminal 'if (count === 3) {' 'if (count >= 3) {'
pass 'every guarded behavior has a red mutation proof'
