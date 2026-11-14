#!/usr/bin/env bash
# Exercise bin/fm-memory.sh and its two consumers over HTTP against a local fm_doc service.
# The service keeps the table's contract: insert-only rows and a 409 on a repeated (scope, path, version).
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'kill "${SERVER:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
printf test > "$TMP/token"; chmod 600 "$TMP/token"
cat > "$TMP/server.py" <<'PY'
import http.server,json,urllib.parse,sys,re
rows=[]
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def send(self,code,body):
  self.send_response(code);self.end_headers();self.wfile.write(json.dumps(body).encode())
 def do_GET(self):
  p=urllib.parse.urlsplit(self.path);q=urllib.parse.parse_qs(p.query)
  if p.path!='/api/fm_doc':return self.send(200,{'success':True,'data':next(r for r in rows if r['id']==p.path.rsplit('/',1)[-1])})
  m=re.fullmatch(r"scope eq '(.*?)' and path eq '(.*?)'(?: and version eq (\d+))?",q['$filter'][0]);found=[r for r in rows if (r['scope'],r['path'])==m.groups()[:2] and (m.group(3) is None or r['version']==int(m.group(3)))]
  found.sort(key=lambda r:-r['version']);top=int(q.get('$top',['100'])[0]);skip=int(q.get('$skip',['0'])[0])
  want=q.get('$select',[''])[0].split(',')
  self.send(200,{'value':[{k:v for k,v in r.items() if k!='content' or 'content' in want} for r in found[skip:skip+top]]})
 def do_POST(self):
  row=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  if any((r['scope'],r['path'],r['version'])==(row['scope'],row['path'],row['version']) for r in rows):return self.send(409,{'error':'duplicate'})
  row['id']=str(len(rows)+1);rows.append(row);self.send(201,row)
s=http.server.HTTPServer(('127.0.0.1',0),H);open(sys.argv[1],'w').write(str(s.server_port));s.serve_forever()
PY
python3 "$TMP/server.py" "$TMP/port" &
SERVER=$!
for _ in $(seq 1 100); do [ ! -s "$TMP/port" ] || break; sleep .02; done
PORT=$(< "$TMP/port")
export FM_TASK_BASE_URL="http://127.0.0.1:$PORT" FM_TASK_TOKEN_FILE="$TMP/token"
MEM="$ROOT/bin/fm-memory.sh"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
field() { printf '%s\n' "$1" | sed -n "s/.*$2=\"\{0,1\}\([^\" ]*\).*/\1/p" | head -1; }

mkhome() {  # <dir>: a home with the three memory files
  mkdir -p "$1/data" "$1/config"
  printf '# Captain preferences\n<!-- memory tiers: see the stow skill -->\n\n- Rule one. <!--p:2026-11-01-->\n- Rule two.\n' > "$1/data/captain.md"
  printf '# Fleet learnings\n\n## Tools <!--a:2026-11-13-->\n\nFirst fact. Second fact. Third fact.\n' > "$1/data/learnings.md"
  printf 'shared\n' > "$1/data/captain-shared.md"
  printf 'cold\n' > "$1/data/memory-archive.md"
  printf '7500\n' > "$1/config/startup-memory-budget"
}
run() { local h=$1; shift; FM_HOME="$h" "$MEM" "$@"; }

# No config/memory-home: sync is silent and changes nothing.
mkhome "$TMP/none"
[ -z "$(run "$TMP/none" sync)" ] || fail "sync without config/memory-home printed output"
[ ! -e "$TMP/none/data/.memory-sync" ] || fail "sync without config/memory-home wrote a record"
ok "a home without config/memory-home is untouched"

# Document families use the same executable path. This service double supplies deterministic
# duplicate/offline responses; real Dev 5001 proof is recorded separately for HF1/HF2.
mkhome "$TMP/docs"; printf 'docs\n' > "$TMP/docs/config/memory-home"
mkdir -p "$TMP/docs/data/handoffs" "$TMP/docs/data/retro" "$TMP/docs/data/project-rules"
printf 'current handoff\n' > "$TMP/docs/data/handoffs/day.md"
ln -s day.md "$TMP/docs/data/handoffs/latest.md"
# shellcheck disable=SC2016 # literal Markdown pointer
printf '**Start here:** `data/handoffs/latest.md`\n' > "$TMP/docs/data/captain.md"
printf 'daily retro\n' > "$TMP/docs/data/retro/2026-11-14.md"
printf 'brief: remote project rule\n' > "$TMP/docs/data/project-rules/cfw-modules.md"
run "$TMP/docs" seed >/dev/null
out=$(run "$TMP/docs" seed)
[ "$(printf '%s\n' "$out" | grep -c 'result="unchanged"')" = 8 ] || fail "family seed not idempotent: $out"
rm "$TMP/docs/data/handoffs/day.md"
run "$TMP/docs" sync >/dev/null
[ -L "$TMP/docs/data/handoffs/latest.md" ] || fail 'sync replaced latest symlink'
[ "$(< "$TMP/docs/data/handoffs/day.md")" = 'current handoff' ] || fail 'sync did not restore handoff'
printf 'unpublished local handoff\n' > "$TMP/docs/data/handoffs/day.md"
line=$(run "$TMP/docs" sync)
[ "$(< "$TMP/docs/data/handoffs/day.md")" = 'unpublished local handoff' ] || fail 'sync lost unpublished handoff'
case "$line" in *waiting_for_put=handoffs/latest.md*) ;; *) fail "missing waiting handoff: $line" ;; esac
rm "$TMP/docs/data/project-rules/cfw-modules.md"
FM_HOME="$TMP/docs" "$ROOT/bin/fm-brief.sh" hf2 cfw-modules --mode direct-PR >/dev/null
[ "$(grep '^brief:' "$TMP/docs/data/hf2/brief.md")" = 'brief: remote project rule' ] || fail 'brief did not read remote rules'
if run "$TMP/docs" show --file '../outside.md' >/dev/null 2>&1; then fail 'unsafe document path accepted'; fi
ok 'document families seed once, restore symlink target and generate a brief without local rules'

# T1: seed twice.
mkhome "$TMP/a"; printf 'probe\n' > "$TMP/a/config/memory-home"
out=$(run "$TMP/a" seed)
[ "$(printf '%s\n' "$out" | grep -c 'result="inserted" version=1')" = 4 ] || fail "seed did not insert four version-1 rows: $out"
out=$(run "$TMP/a" seed)
[ "$(printf '%s\n' "$out" | grep -c 'result="unchanged"')" = 4 ] || fail "second seed was not a no-op: $out"
[ "$(run "$TMP/a" history --file captain.md | wc -l)" = 1 ] || fail "seed twice left more than one captain.md version"
ok "seed inserts version 1 once and is idempotent"

# T2: a removed cache file comes back from 5001.
orig=$(cat "$TMP/a/data/captain.md"); rm "$TMP/a/data/captain.md"
line=$(run "$TMP/a" sync)
case "$line" in memory_source=5001*captain.md=v1*) ;; *) fail "sync line was: $line" ;; esac
[ "$(cat "$TMP/a/data/captain.md")" = "$orig" ] || fail "pull did not restore captain.md from 5001"
ok "sync restores a removed captain.md from 5001"

# T3: put raises the version by one and the rules row follows; the old version stays readable.
printf '\nA new fact. <!--a:2026-11-14-->\n' >> "$TMP/a/data/learnings.md"
out=$(run "$TMP/a" put --file learnings.md)
[ "$(field "$out" version)" = 2 ] || fail "put did not insert version 2: $out"
hist=$(run "$TMP/a" history --file learnings.md)
case "$hist" in *version=2*version=1*) ;; *) fail "history lost a version: $hist" ;; esac
rules=$(curl -s -H 'authorization: Bearer test' "$FM_TASK_BASE_URL/api/fm_doc?\$filter=scope%20eq%20'home:probe'%20and%20path%20eq%20'learnings.md.rules.json'&\$select=version,content")
case "$rules" in *'"version": 2'*'A new fact'*) ;; *) fail "rules row for version 2 is missing: $rules" ;; esac
out=$(run "$TMP/a" put --file learnings.md)
[ "$(field "$out" result)" = unchanged ] || fail "put of unchanged text was not a no-op: $out"
ok "put inserts exactly version n+1 with its rules row"

# T4: a lost race refuses with a diff and writes nothing.
mkhome "$TMP/b"; printf 'probe\n' > "$TMP/b/config/memory-home"; run "$TMP/b" pull >/dev/null
printf 'edit from b\n' >> "$TMP/b/data/captain.md"
printf 'edit from a\n' >> "$TMP/a/data/captain.md"
run "$TMP/a" put --file captain.md >/dev/null
set +e; err=$(run "$TMP/b" put --file captain.md 2>&1); rc=$?; set -e
[ "$rc" = 3 ] || fail "lost race exit code was $rc: $err"
case "$err" in *'+edit from b'*) ;; *) fail "refusal showed no diff: $err" ;; esac
[ "$(run "$TMP/b" history --file captain.md | wc -l)" = 2 ] || fail "lost race wrote a row"
[ "$(run "$TMP/b" pull | grep -c 'kept: local edit')" -ge 1 ] || fail "pull overwrote a waiting edit"
grep -q 'edit from b' "$TMP/b/data/captain.md" || fail "waiting edit was lost"
ok "a lost race refuses with a diff and keeps the waiting edit"

# Reconcile by hand: show the 5001 text, apply the edit on it, put --rebase.
run "$TMP/b" show --file captain.md > "$TMP/b-theirs.md"
grep -q 'edit from a' "$TMP/b-theirs.md" || fail "show did not print the 5001 text"
[ "$(run "$TMP/b" show --file captain.md --version 1 | grep -c 'edit from')" = 0 ] || fail "show --version 1 printed a later text"
{ cat "$TMP/b-theirs.md"; printf 'edit from b\n'; } > "$TMP/b/data/captain.md"
out=$(run "$TMP/b" put --file captain.md --rebase)
[ "$(field "$out" version)" = 3 ] || fail "put --rebase did not insert version 3: $out"
run "$TMP/a" pull | grep -q 'captain.md.*written' || fail "the other cache did not receive version 3"
grep -q 'edit from b' "$TMP/a/data/captain.md" || fail "version 3 text missing in the other cache"
ok "a refusal is reconciled with show and put --rebase"

# T5: offline.
cache=$(cat "$TMP/a/data/captain.md")
line=$(FM_TASK_BASE_URL=http://127.0.0.1:9 run "$TMP/a" sync)
case "$line" in memory_source=cache*cache_written=*) ;; *) fail "offline sync line was: $line" ;; esac
[ "$(cat "$TMP/a/data/captain.md")" = "$cache" ] || fail "offline sync changed the cache"
printf 'offline edit\n' >> "$TMP/a/data/learnings.md"
if FM_TASK_BASE_URL=http://127.0.0.1:9 run "$TMP/a" put --file learnings.md 2>/dev/null; then fail "offline put succeeded"; fi
out=$(run "$TMP/a" put --file learnings.md)
[ "$(field "$out" version)" = 3 ] || fail "the waiting edit did not upload as n+1: $out"
ok "offline sync prints the cache age and a waiting edit uploads as n+1"

# Review fixes: a slow 5001 holds sync for 5 s in total, not 5 s per request.
cat > "$TMP/slow.py" <<'PY'
import http.server,json,sys,time
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  time.sleep(4);self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'value':[]}).encode())
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);open(sys.argv[1],'w').write(str(s.server_port));s.serve_forever()
PY
python3 "$TMP/slow.py" "$TMP/slow-port" &
SLOW=$!
for _ in $(seq 1 100); do [ ! -s "$TMP/slow-port" ] || break; sleep .02; done
start=$(date +%s)
line=$(FM_TASK_BASE_URL="http://127.0.0.1:$(< "$TMP/slow-port")" run "$TMP/a" sync)
took=$(( $(date +%s) - start ))
kill "$SLOW" 2>/dev/null || true
case "$line" in memory_source=cache*) ;; *) fail "a slow 5001 did not fall back to the cache: $line" ;; esac
[ "$took" -le 7 ] || fail "sync waited ${took}s on a slow 5001, wanted at most 7s"
ok "sync on a slow 5001 ends within its 5 s deadline and reports the cache"

# T6: the budget report measures the 5001 text, not a stale cache.
mkdir -p "$TMP/c/config"; printf '7500\n' > "$TMP/c/config/startup-memory-budget"; printf 'probe\n' > "$TMP/c/config/memory-home"; run "$TMP/c" pull >/dev/null  # a stale cache: pulled, then 5001 moves on
printf 'a much longer learnings text that only 5001 holds now, long enough to change the byte count\n' >> "$TMP/a/data/learnings.md"
run "$TMP/a" put --file learnings.md >/dev/null
want=$(wc -c < "$TMP/a/data/learnings.md" | tr -d ' ')
report=$(FM_HOME="$TMP/c" "$ROOT/bin/fm-startup-memory-budget.sh" report)
case "$report" in *memory_source=5001*) ;; *) fail "budget report named no 5001 source: $report" ;; esac
case "$report" in *"file=data/learnings.md bytes=$want "*) ;; *) fail "budget report measured a stale cache, wanted $want bytes: $report" ;; esac
ok "budget report reads the 5001 text"

# Review fixes: a secondmate never reads or writes its inherited captain-shared.md on 5001.
mkhome "$TMP/sm"; printf 'sm1\n' > "$TMP/sm/config/memory-home"; : > "$TMP/sm/.fm-secondmate-home"
out=$(run "$TMP/sm" seed)
[ "$(printf '%s\n' "$out" | grep -c 'result="inserted"')" = 3 ] || fail "secondmate seed did not skip captain-shared.md: $out"
rm "$TMP/sm/data/captain-shared.md"; run "$TMP/sm" sync >/dev/null
[ ! -e "$TMP/sm/data/captain-shared.md" ] || fail "sync restored the inherited captain-shared.md"
if run "$TMP/sm" put --file captain-shared.md 2>/dev/null; then fail "secondmate put of captain-shared.md succeeded"; fi
run "$TMP/sm" rules --file captain-shared.md >/dev/null 2>&1 || true
printf 'shared\n' > "$TMP/sm/data/captain-shared.md"
[ -n "$(run "$TMP/sm" rules --file captain-shared.md)" ] || fail "a secondmate could not inspect the rules of its local captain-shared.md"
ok "a secondmate home leaves the inherited captain-shared.md alone"

# Review fixes: a pull record from another home is never published into this one.
mkhome "$TMP/x"; printf 'homea\n' > "$TMP/x/config/memory-home"; run "$TMP/x" seed >/dev/null
mkhome "$TMP/y"; printf 'homeb\n' > "$TMP/y/config/memory-home"; run "$TMP/y" seed >/dev/null
printf 'edit based on home a\n' >> "$TMP/x/data/captain.md"
printf 'homeb\n' > "$TMP/x/config/memory-home"
set +e; err=$(run "$TMP/x" put --file captain.md 2>&1); rc=$?; set -e
[ "$rc" != 0 ] || fail "put published a record based on another home"
case "$err" in *'is for home:homea, not home:homeb'*) ;; *) fail "scope refusal was: $err" ;; esac
[ "$(run "$TMP/y" history --file captain.md | wc -l)" = 1 ] || fail "home b gained a version"
ok "put refuses a pull record from another memory home"

# Review fixes: a pull record from another home is never published into an empty home either.
mkhome "$TMP/z"; printf 'homez\n' > "$TMP/z/config/memory-home"; run "$TMP/z" seed >/dev/null
printf 'homenew\n' > "$TMP/z/config/memory-home"
set +e; err=$(run "$TMP/z" put --file learnings.md 2>&1); rc=$?; set -e
[ "$rc" != 0 ] || fail "put published a record of home z into the empty home"
case "$err" in *'is for home:homez, not home:homenew'*) ;; *) fail "empty-home scope refusal was: $err" ;; esac
[ "$(run "$TMP/z" history --file learnings.md | wc -l)" = 0 ] || fail "the empty home gained a version"
out=$(run "$TMP/z" put --file learnings.md --rebase)
[ "$(field "$out" version)" = 1 ] || fail "put --rebase into the empty home did not insert version 1: $out"
ok "put refuses another home's pull record into an empty home unless --rebase"

# T7: the rule splitter.
long=$(python3 -c "print(' '.join(f'Sentence number {i} is a short fact.' for i in range(30)))")
printf '# Fleet learnings\n\n## Tools <!--a:2026-11-13-->\n\n%s\n\n- not a bullet rule here\n' "$long" > "$TMP/split-learnings.md"
mkdir -p "$TMP/split"; cp "$TMP/split-learnings.md" "$TMP/split/learnings.md"
# shellcheck disable=SC2016 # the backticks are literal fixture text
printf '# Captain preferences\n<!-- memory tiers: see the stow skill -->\n\n**Start here:** read `a.b`. <!--p:2026-11-13-->\n\n## Workers\n\n- First rule (2026-01-01): one. Two. e.g. three.\n  continues here.\n- Pinned rule. <!--P-->\n- Aging rule. <!--a:2026-10-01/3-->\n' > "$TMP/split/captain.md"
node "$ROOT/bin/fm-memory-lib.mjs" rules --home t --data "$TMP/split" --file captain.md > "$TMP/rc.json"
node "$ROOT/bin/fm-memory-lib.mjs" rules --home t --data "$TMP/split" --file learnings.md > "$TMP/rl.json"
mkdir -p "$TMP/split2"; printf '# Fleet learnings\n\n## Tools <!--a:2026-11-01-->\n\n%s <!--p:2026-11-13-->\n' "$long" > "$TMP/split2/learnings.md"
node "$ROOT/bin/fm-memory-lib.mjs" rules --home t --data "$TMP/split2" --file learnings.md > "$TMP/rm.json"
python3 - "$TMP" <<'PY'
import json,sys
t=sys.argv[1];c=json.load(open(t+'/rc.json'));l=json.load(open(t+'/rl.json'))
assert [x['text'][:12] for x in c]==['**Start here','- First rule','- Pinned rul','- Aging rule'],c
assert c[0]['tier']=='perishable' and c[0]['date']=='2026-11-13'
assert c[1]['section']=='Workers' and c[1]['tier']=='pinned' and 'continues here.' in c[1]['text'] and 'e.g. three.' in c[1]['text']
assert c[2]['tier']=='pinned' and c[3]['tier']=='aging' and c[3]['date']=='2026-10-01'
assert all(x['bytes']==len(x['text'].encode()) and x['tokens']==-(-x['bytes']//3) for x in c+l)
assert len(l)>=4 and all(x['bytes']<=400 for x in l[:-1]) and all(x['tier']=='aging' and x['date']=='2026-11-13' for x in l[:-1])
assert ' '.join(x['text'] for x in l[:-1]).startswith('Sentence number 0')
m=json.load(open(t+'/rm.json'));assert len(m)>=3 and all(x['tier']=='perishable' and x['date']=='2026-11-13' for x in m),m
PY
ok "rule splitter keeps bullets whole, cuts learnings at sentence ends and reads tiers"
