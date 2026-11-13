#!/usr/bin/env bash
# Exercise the document CLI through HTTP and real committed git objects.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'kill "${SERVER:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
printf test > "$TMP/token"
chmod 600 "$TMP/token"
git init -q "$TMP/repo"
git -C "$TMP/repo" config user.email test@example.invalid
git -C "$TMP/repo" config user.name Test
printf original > "$TMP/repo/AGENTS.md"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -qm initial
cat > "$TMP/server.py" <<'PY'
import http.server,json,urllib.parse,sys
rows=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  p=urllib.parse.urlsplit(self.path)
  if p.path=='/api/fm_doc':
   q=urllib.parse.parse_qs(p.query);skip=int(q.get('$skip',['0'])[0]);body={'value':[{k:v for k,v in r.items() if k!='content'} for r in rows[skip:skip+100]]}
  else:body=next(r for r in rows if r['id']==p.path.rsplit('/',1)[-1])
  self.send_response(200);self.end_headers();self.wfile.write(json.dumps(body).encode())
 def do_POST(self):
  row=json.loads(self.rfile.read(int(self.headers['Content-Length'])));row['id']=str(len(rows)+1);rows.append(row)
  self.send_response(201);self.end_headers();self.wfile.write(json.dumps(row).encode())
s=http.server.HTTPServer(('127.0.0.1',0),Handler);open(sys.argv[1],'w').write(str(s.server_port));s.serve_forever()
PY
python3 "$TMP/server.py" "$TMP/port" &
SERVER=$!
for _ in $(seq 1 100); do [ ! -s "$TMP/port" ] || break; sleep .02; done
export FM_TASK_BASE_URL="http://127.0.0.1:$(< "$TMP/port")" FM_TASK_TOKEN_FILE="$TMP/token"
DOC="$ROOT/bin/fm-doc.sh"
"$DOC" publish --repo firstmate --root "$TMP/repo" --json > "$TMP/first"
printf dirty > "$TMP/repo/AGENTS.md"
"$DOC" publish --repo firstmate --root "$TMP/repo" --json > "$TMP/retry"
"$DOC" get --path firstmate/AGENTS.md --full --json > "$TMP/get"
"$DOC" materialize --repo firstmate --output "$TMP/export" --json >/dev/null
[ "$(< "$TMP/export/firstmate/AGENTS.md")" = original ]
printf changed > "$TMP/repo/AGENTS.md"
git -C "$TMP/repo" commit -qam changed
if "$DOC" diff --repo firstmate --root "$TMP/repo" --json > "$TMP/diff"; then exit 1; fi
"$DOC" publish --repo firstmate --root "$TMP/repo" --json >/dev/null
"$DOC" diff --repo firstmate --root "$TMP/repo" --json > "$TMP/clean"
git -C "$TMP/repo" rm -q AGENTS.md
git -C "$TMP/repo" commit -qm deleted
"$DOC" publish --repo firstmate --root "$TMP/repo" --json >/dev/null
"$DOC" list --json > "$TMP/deleted"
if "$DOC" get --path firstmate/../escape; then exit 1; fi
if "$DOC" list --unknown; then exit 1; fi
python3 - "$TMP" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);read=lambda n:json.loads((p/n).read_text())
assert read('first')['inserted']==1
assert read('retry')['inserted']==0
assert read('get')['content']=='original'
d=read('diff');assert len(d)==1 and d[0]['path']=='firstmate/AGENTS.md' and d[0]['localSha']!=d[0]['publishedSha']
assert read('clean')==[] and read('deleted')==[]
PY
printf 'PASS: document CLI committed publication, retry, export, drift, deletion and path refusal\n'
