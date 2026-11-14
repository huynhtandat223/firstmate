#!/usr/bin/env bash
# Exercise private material through the real CLI: an HTTP double of fm_doc, real files and real git repositories.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'kill "${SERVER:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
printf test > "$TMP/token"; chmod 600 "$TMP/token"
cat > "$TMP/server.py" <<'PY'
import http.server, json, re, sys, urllib.parse
rows = []
def terms(expr):
    parts, depth, cur = [], 0, ''
    for chunk in re.split(r'( and | or )', expr):
        if chunk in (' and ', ' or ') and depth == 0:
            parts.append(cur); parts.append(chunk.strip()); cur = ''; continue
        cur += chunk; depth += chunk.count('(') - chunk.count(')')
    parts.append(cur); return parts
def match(row, expr):
    expr = expr.strip()
    if expr.startswith('(') and expr.endswith(')') and len(terms(expr[1:-1])) > 1: return match(row, expr[1:-1])
    parts = terms(expr)
    if len(parts) > 1:
        results = [match(row, p) for p in parts[0::2]]
        return all(results) if parts[1] == 'and' else any(results)
    m = re.match(r"(\w+) eq '([^']*)'$", expr)
    if not m: raise ValueError(expr)
    return str(row.get(m.group(1))) == m.group(2)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        self.send_response(code); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        p = urllib.parse.urlsplit(self.path); q = urllib.parse.parse_qs(p.query)
        if p.path == '/dump': return self.send(200, rows)
        if p.path == '/api/fm_doc':
            found = [r for r in rows if match(r, q['$filter'][0])] if '$filter' in q else list(rows)
            skip = int(q.get('$skip', ['0'])[0]); top = int(q.get('$top', ['100'])[0])
            return self.send(200, {'value': [{k: v for k, v in r.items() if k != 'content'} for r in found[skip:skip + top]]})
        self.send(200, {'success': True, 'data': next(r for r in rows if r['id'] == p.path.rsplit('/', 1)[-1])})
    def do_POST(self):
        row = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if any(r['scope'] == row['scope'] and r['path'] == row['path'] and r['version'] == row['version'] for r in rows): return self.send(409, {})
        row['id'] = str(len(rows) + 1); rows.append(row); self.send(201, row)
s = http.server.HTTPServer(('127.0.0.1', 0), Handler); open(sys.argv[1], 'w').write(str(s.server_port)); s.serve_forever()
PY
python3 "$TMP/server.py" "$TMP/port" &
SERVER=$!
for _ in $(seq 1 100); do [ ! -s "$TMP/port" ] || break; sleep .02; done
PORT=$(< "$TMP/port")
export FM_TASK_BASE_URL="http://127.0.0.1:$PORT" FM_TASK_TOKEN_FILE="$TMP/token" FM_HOST_ID=host-a
DOC="$ROOT/bin/fm-doc.sh"
dump() { curl -s "http://127.0.0.1:$PORT/dump" > "$TMP/dump.json"; }
rowcount() { dump; python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/dump.json"; }

# Home A: a git repository holding portable files, machine-only files, backups and one tracked skill.
A="$TMP/home-a"; mkdir -p "$A"; git init -q "$A"
git -C "$A" config user.email t@example.invalid; git -C "$A" config user.name T
mkdir -p "$A/config/roles" "$A/config/assistances" "$A/config/tasks-axi" "$A/data/firstmate-tools/sub/__pycache__" "$A/.agents/skills/mine" "$A/.agents/skills/shipped"
printf 'pi\n' > "$A/config/crew-harness"; : > "$A/config/dispatch-plan-gate"; printf 'id-1\n' > "$A/config/notify-recipient"
printf '{"a":1}\n' > "$A/config/pr-review.json"; printf 'role one\n' > "$A/config/roles/tester.md"; printf 'old\n' > "$A/config/roles/tester.md.bak-1"
printf '{"x":1}\n' > "$A/config/assistances/dms.json"; printf '/home/me/.claude-a\n' > "$A/config/claude-account"
printf 'herdr\n' > "$A/config/backend"; printf 'shadow\n' > "$A/config/task-shadow"; printf 'host\n' > "$A/config/supervision-host"
printf 'host-a\n' > "$A/config/host-id"; printf 'x\n' > "$A/config/tasks-axi/.tasks.toml"; printf 'new\n' > "$A/config/unlisted-new-file"
printf 'secret-ish\n' > "$A/config/github.token"; printf 'notes\n' > "$A/data/chatgpt-review.md"
printf '#!/usr/bin/env bash\necho tool\n' > "$A/data/firstmate-tools/tool.sh"; chmod 755 "$A/data/firstmate-tools/tool.sh"
printf 'nested\n' > "$A/data/firstmate-tools/sub/nested.md"; printf 'x' > "$A/data/firstmate-tools/sub/__pycache__/x.pyc"
printf 'x' > "$A/data/firstmate-tools/.scratch.sh"; printf 'k' > "$A/data/firstmate-tools/vault.token"
printf -- '---\nname: mine\n---\nprivate\n' > "$A/.agents/skills/mine/SKILL.md"; printf 'tracked\n' > "$A/.agents/skills/shipped/SKILL.md"
git -C "$A" add .agents/skills/shipped && git -C "$A" commit -qm skill
export FM_HOME="$A"

# T1: seed takes only the listed files.
"$DOC" seed --home main > "$TMP/seed1"
"$DOC" status --home main > "$TMP/status1"
N1=$(rowcount)
"$DOC" seed --home main > "$TMP/seed2"
[ "$(rowcount)" = "$N1" ] || { echo 'second seed inserted rows'; exit 1; }
python3 - "$TMP" <<'PY'
import json, pathlib, sys
t = pathlib.Path(sys.argv[1]); rows = json.load(open(t / 'dump.json'))
got = {(r['scope'], r['path']): r['kind'] for r in rows if r['kind'] not in ('holding', 'index')}
want = {('home:main', 'config/crew-harness'): 'config', ('home:main', 'config/dispatch-plan-gate'): 'config', ('home:main', 'config/notify-recipient'): 'config',
 ('home:main', 'config/pr-review.json'): 'config', ('home:main', 'config/roles/tester.md'): 'role', ('home:main', 'config/assistances/dms.json'): 'config',
 ('host:host-a', 'config/claude-account'): 'config', ('home:main', 'data/chatgpt-review.md'): 'doc', ('home:main', 'data/firstmate-tools/tool.sh'): 'tool',
 ('home:main', 'data/firstmate-tools/sub/nested.md'): 'tool', ('home:main', '.agents/skills/mine/SKILL.md'): 'private-skill'}
assert got == want, (set(got) ^ set(want))
for name in ('backend', 'task-shadow', 'supervision-host', 'host-id', 'tasks-axi', '.bak', 'unlisted', 'token', 'pycache', 'shipped', '.scratch'):
    assert not any(name in r['path'] for r in rows), name
assert all(r['source'] == '5001' for r in rows)
status = (t / 'status1').read_text()
for name in ('config/backend', 'config/task-shadow', 'config/unlisted-new-file', 'config/github.token', 'config/tasks-axi'): assert f'path="{name}" state="not-portable"' in status, name
assert 'path="config/crew-harness" kind="config" state="current" remote=1' in status
PY

# T2: a token-shaped line refuses the whole seed.
printf '#!/usr/bin/env bash\nexport X="Bearer abcdefghijklmnopqrstuvwxyz0123456789"\n' > "$A/data/firstmate-tools/leak.sh"
printf 'changed\n' > "$A/config/reply-language"
BEFORE=$(rowcount)
if "$DOC" seed --home main > "$TMP/leak.out" 2> "$TMP/leak.err"; then echo 'seed accepted a secret'; exit 1; else [ $? -eq 4 ]; fi
grep -q 'data/firstmate-tools/leak.sh (bearer token)' "$TMP/leak.err"
[ "$(rowcount)" = "$BEFORE" ] || { echo 'rows inserted despite the guard'; exit 1; }
rm "$A/data/firstmate-tools/leak.sh" "$A/config/reply-language"

# T3: materialize into an empty probe home is byte-equal and keeps the script executable.
B="$TMP/home-b"; mkdir -p "$B"
FM_HOME="$B" "$DOC" materialize --home main > "$TMP/mat1"
for f in config/crew-harness config/dispatch-plan-gate config/notify-recipient config/pr-review.json config/roles/tester.md config/assistances/dms.json config/claude-account data/chatgpt-review.md data/firstmate-tools/tool.sh data/firstmate-tools/sub/nested.md .agents/skills/mine/SKILL.md; do
  cmp "$A/$f" "$B/$f"
done
[ -x "$B/data/firstmate-tools/tool.sh" ] && [ ! -x "$B/data/chatgpt-review.md" ]
[ "$(stat -c %a "$B/config/claude-account")" = 600 ]
for f in config/backend config/task-shadow config/supervision-host config/host-id config/roles/tester.md.bak-1; do [ ! -e "$B/$f" ] || { echo "machine-only file written: $f"; exit 1; }; done
N2=$(rowcount); [ "$N2" = "$N1" ] || { echo 'materialize without --record wrote rows'; exit 1; }

# T4: a local edit is kept by materialize and uploaded as n+1 by sync. Home B runs as host-b, so its copied account pin
# is a new file of that host (uploaded=2: the edit and the pin).
printf 'claude\n' > "$B/config/crew-harness"
FM_HOME="$B" "$DOC" materialize --home main | grep -q 'kept: local edit waiting for put'
[ "$(cat "$B/config/crew-harness")" = claude ]
FM_HOME="$B" FM_HOST_ID=host-b "$DOC" sync --home main > "$TMP/sync-b"
grep -q 'material_source=5001 home=main .*uploaded=2 ' "$TMP/sync-b" || { cat "$TMP/sync-b"; exit 1; }
dump; python3 - "$TMP" <<'PY'
import json, pathlib, sys
rows = json.load(open(pathlib.Path(sys.argv[1]) / 'dump.json'))
v = sorted((r['version'], r['content']) for r in rows if r['path'] == 'config/crew-harness')
assert v == [(1, 'pi\n'), (2, 'claude\n')], v
PY

# T5: home A edits the old version; sync reports a conflict, put refuses with the diff, nothing is written.
printf 'codex\n' > "$A/config/crew-harness"
BEFORE=$(rowcount)
FM_HOME="$A" "$DOC" sync --home main > "$TMP/sync-a"
grep -q 'material_conflict path="config/crew-harness"' "$TMP/sync-a"; grep -q 'conflicts=1' "$TMP/sync-a"
[ "$(cat "$A/config/crew-harness")" = codex ]
if "$DOC" put --home main --path config/crew-harness > "$TMP/put.out" 2> "$TMP/put.err"; then echo 'put overwrote'; exit 1; else [ $? -eq 3 ]; fi
grep -q '^-pi' "$TMP/put.err" || grep -q '^-claude' "$TMP/put.err"; grep -q '^+codex' "$TMP/put.err"
[ "$(rowcount)" = "$BEFORE" ] || { echo 'rows inserted on a lost race'; exit 1; }
"$DOC" put --home main --path config/crew-harness --rebase | grep -q 'version=3'

# T6: unreachable 5001 keeps the files and prints the cache line.
FM_TASK_BASE_URL=http://127.0.0.1:9 "$DOC" sync --home main > "$TMP/offline"
grep -q 'material_source=cache home=main cache_written=' "$TMP/offline"; grep -q 'reason=' "$TMP/offline"
[ "$(cat "$A/config/crew-harness")" = codex ]

# T7: remove backs up, inserts a tombstone and deletes; a probe home drops or skips it.
"$DOC" remove --home main --path config/roles/tester.md > "$TMP/remove"
BACKUP=$(sed -n 's/.*backup="\([^"]*\)".*/\1/p' "$TMP/remove"); [ -f "$BACKUP" ] && [ "$(cat "$BACKUP")" = 'role one' ]
[ ! -e "$A/config/roles/tester.md" ]
dump; python3 -c 'import json,sys;r=[x for x in json.load(open(sys.argv[1])) if x["path"]=="config/roles/tester.md"];assert sorted(x["version"] for x in r)==[1,2] and any(x["mediaType"]=="application/x-fm-deleted" for x in r)' "$TMP/dump.json"
FM_HOME="$B" "$DOC" materialize --home main | grep -q 'config/roles/tester.md" result="removed"'
[ ! -e "$B/config/roles/tester.md" ]
C="$TMP/home-c"; mkdir -p "$C"; FM_HOME="$C" "$DOC" materialize --home main > /dev/null; [ ! -e "$C/config/roles/tester.md" ]
"$DOC" status --home main | grep -q 'path="config/roles/tester.md".*not' && { echo 'status lists a removed file'; exit 1; } || true

# Review round 1: a removed file stays removed. A stale copy cannot resurrect it through seed.
S="$TMP/home-stale"; mkdir -p "$S/config/roles"; printf 'role one\n' > "$S/config/roles/tester.md"
BEFORE=$(rowcount)
FM_HOME="$S" FM_HOST_ID=host-s "$DOC" seed --home main | grep -q 'config/roles/tester.md" result="removed on 5001: use put --rebase to restore"'
[ "$(rowcount)" -eq "$BEFORE" ] || [ "$(rowcount)" -gt "$BEFORE" ]  # other files of the stale home may insert; the removed one must not
dump; python3 -c 'import json,sys;r=[x for x in json.load(open(sys.argv[1])) if x["path"]=="config/roles/tester.md"];assert sorted(x["version"] for x in r)==[1,2],r' "$TMP/dump.json"

# Review round 1: remove refuses a copy that is behind 5001 (B updates, A removes without syncing).
printf 'id-2\n' > "$B/config/notify-recipient"
FM_HOME="$B" FM_HOST_ID=host-b "$DOC" sync --home main > /dev/null
BEFORE=$(rowcount)
if "$DOC" remove --home main --path config/notify-recipient > "$TMP/stale-remove.out" 2> "$TMP/stale-remove.err"; then echo 'remove tombstoned a newer version'; exit 1; else [ $? -eq 3 ]; fi
grep -q 'nothing was removed' "$TMP/stale-remove.err"; [ -f "$A/config/notify-recipient" ]; [ "$(rowcount)" = "$BEFORE" ]

# Review round 1: put applies the same file checks as discovery, so a link out of the home is never uploaded.
printf 'outside\n' > "$TMP/outside.md"; ln -s "$TMP/outside.md" "$A/data/firstmate-tools/link.md"
BEFORE=$(rowcount)
if "$DOC" put --home main --path data/firstmate-tools/link.md 2> "$TMP/link.err"; then echo 'put followed a link'; exit 1; fi
grep -q 'not a regular file' "$TMP/link.err"; [ "$(rowcount)" = "$BEFORE" ]
"$DOC" status --home main | grep -q 'path="data/firstmate-tools/link.md" state="not-portable" reason="folder or link'
rm "$A/data/firstmate-tools/link.md"

# Review round 1: holdings of one home never take the versions of another home on the same machine.
"$DOC" seed --home other > /dev/null
"$DOC" put --home main --path config/crew-harness > /dev/null   # unchanged text: rewrites the holdings of home main with both homes in the state file
dump; python3 - "$TMP" <<'PY'
import json, pathlib, sys
rows = json.load(open(pathlib.Path(sys.argv[1]) / 'dump.json'))
def held(name):
    r = max((x for x in rows if x['scope'] == 'host:host-a' and x['path'] == f'holdings/{name}.json'), key=lambda x: x['version'])
    return json.loads(r['content'])
assert held('main')['config/crew-harness'] == 3, held('main')['config/crew-harness']
assert held('other')['config/crew-harness'] == 1, held('other')['config/crew-harness']
PY

# Settings index and holdings: what the page shows.
dump; python3 - "$TMP" <<'PY'
import json, pathlib, sys
rows = json.load(open(pathlib.Path(sys.argv[1]) / 'dump.json'))
index = max((r for r in rows if r['path'] == 'settings.index.json'), key=lambda r: r['version'])
items = {i['path']: i for i in json.loads(index['content'])}
assert items['config/crew-harness']['version'] == 3 and 'host-a=v3' in items['config/crew-harness']['machines'], items['config/crew-harness']
assert 'host-b=v3' in items['config/crew-harness']['machines'], items['config/crew-harness']
assert items['config/claude-account (host-a)']['kind'] == 'config'
assert 'config/roles/tester.md' not in items and 'config/backend' not in items
assert any(r['scope'] == 'host:host-a' and r['kind'] == 'holding' for r in rows)
assert all(r['scope'] != 'home:main' or r['kind'] != 'memory' for r in rows)
PY

# A path that is not portable is never written, even when 5001 holds it.
python3 - "$PORT" <<'PY'
import json, sys, urllib.request
for path in ('config/backend', 'config/../evil', 'config/assistances/steal.token', '.agents/skills/shipped/SKILL.md'):
    req = urllib.request.Request(f'http://127.0.0.1:{sys.argv[1]}/api/fm_doc', json.dumps({'scope': 'home:main', 'path': path, 'version': 1, 'kind': 'config', 'source': '5001', 'mediaType': 'text/plain', 'content': 'bad'}).encode(), {'content-type': 'application/json'})
    urllib.request.urlopen(req)
PY
D="$TMP/home-d"; mkdir -p "$D"; git init -q "$D"; mkdir -p "$D/.agents/skills/shipped"; printf 'tracked\n' > "$D/.agents/skills/shipped/SKILL.md"
git -C "$D" config user.email t@example.invalid; git -C "$D" config user.name T; git -C "$D" add . && git -C "$D" commit -qm s
FM_HOME="$D" "$DOC" materialize --home main > "$TMP/mat-d"
[ ! -e "$D/config/backend" ] && [ ! -e "$D/config/evil" ] && [ ! -e "$D/config/assistances/steal.token" ] && [ "$(cat "$D/.agents/skills/shipped/SKILL.md")" = tracked ]
grep -q 'config/backend" result="refused path"' "$TMP/mat-d"

# A materialized private skill is excluded from git status in a git home.
[ -z "$(git -C "$D" status --porcelain -- .agents)" ] || { echo 'private skill shows as untracked'; git -C "$D" status --porcelain -- .agents; exit 1; }

# Review round 1: session start never waits for the network. With a 5001 that never answers, the digest still prints
# and names the sync as pending; the bounded worker then settles with the cache line.
Q="$TMP/home-ss"; mkdir -p "$Q/config" "$Q/data" "$Q/state"; git init -q "$Q"; printf 'main\n' > "$Q/config/material-home"
python3 - "$TMP/hang-port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(8); open(sys.argv[1], 'w').write(str(s.getsockname()[1]))
conns = []
while True: conns.append(s.accept()[0]); time.sleep(0)
PY
HANG=$!
for _ in $(seq 1 100); do [ ! -s "$TMP/hang-port" ] || break; sleep .02; done
START=$(date +%s)
FM_HOME="$Q" FM_TASK_BASE_URL="http://127.0.0.1:$(< "$TMP/hang-port")" FM_MATERIAL_SYNC_TIMEOUT=30 timeout 100 "$ROOT/bin/fm-session-start.sh" > "$TMP/ss.out" 2>&1 || true
ELAPSED=$(( $(date +%s) - START ))
grep -q 'material_source=pending home=main' "$TMP/ss.out" || { echo 'digest lacks the pending line'; exit 1; }
[ "$ELAPSED" -lt 25 ] || { echo "session start waited for the network: ${ELAPSED}s"; exit 1; }
for _ in $(seq 1 120); do [ -s "$Q/state/.material-sync.out" ] && break; sleep 1; done
grep -q 'material_source=cache home=main' "$Q/state/.material-sync.out"
kill "$HANG" 2>/dev/null || true

# The C1 git export keeps working through the same entry point.
if "$DOC" materialize --repo firstmate --output "$TMP/export-should-fail" --unknown 2>/dev/null; then exit 1; fi
if "$DOC" list --unknown; then exit 1; fi
printf 'PASS: private material seed, secret guard, materialize, edit, lost race, offline, remove, index and path safety\n'
