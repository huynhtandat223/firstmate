#!/usr/bin/env bash
# Exercise notify-me through its CLI and an HTTP fixture, without live credentials.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '[[ -z ${server:-} ]] || kill "$server" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/home/.local/share/cfw-scripts-private"
printf 'fixture-token' > "$work/home/.local/share/cfw-scripts-private/notify-firstmate.token"
chmod 600 "$work/home/.local/share/cfw-scripts-private/notify-firstmate.token"
cat > "$work/server.py" <<'PY'
import http.server,json,pathlib,sys,urllib.parse
root=pathlib.Path(sys.argv[1]); notification=None; decided=False
ident='11111111-2222-3333-4444-555555555555'
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def reply(self,status,data):
  self.send_response(status); self.end_headers(); self.wfile.write(json.dumps(data).encode())
 def do_POST(self):
  global notification
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  assert self.headers['Authorization']=='Bearer fixture-token'
  assert self.path=='/api/notification'
  if body['dedupeKey']=='refused': return self.reply(403,{'message':'fixture-token'})
  if body['dedupeKey']=='bad-conflict': return self.reply(409,{'errorCode':'OTHER'})
  if notification is not None:
   return self.reply(409,{'errorCode':'UNIQUE_KEY_CONFLICT','details':{'existingId':ident}})
  assert 'producer' not in body and 'createdAt' not in body
  assert body['recipient']=='fixture-owner' and body['kind']=='notification'
  assert body['title']=='Quote " and newline\n' and body['body']=='Plain body'
  assert body['severity']=='warning' and body['link']=='https://example.org/review'
  assert body['actions']==[{'actionId':'approve','label':'Approve: now'},{'actionId':'reject','label':'Reject'}]
  notification=body
  (root/'posted').write_text(json.dumps(body))
  self.reply(201,{'success':True,'data':{'id':ident}})
 def do_GET(self):
  assert self.headers['Authorization']=='Bearer fixture-token'
  query=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
  assert query['$filter']==['notificationId eq '+ident] and query['$top']==['1']
  self.reply(200,{'value':[{'actionId':'approve','note':'Go','decidedBy':'owner','decidedAt':'now'}] if (root/'decided').exists() else []})
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port))
server.serve_forever()
PY
python3 "$work/server.py" "$work" & server=$!
for ((i=0;i<100;i++)); do [[ ! -f $work/port ]] || break; sleep 0.05; done
[[ -f $work/port ]] || { echo 'server did not start' >&2; exit 1; }
HOME="$work/home"
FM_NOTIFY_BASE_URL="http://127.0.0.1:$(<"$work/port")"
FM_HOME="$work/fm-home"
mkdir -p "$FM_HOME/config"
printf 'fixture-owner\n' > "$FM_HOME/config/notify-recipient"
export HOME FM_NOTIFY_BASE_URL FM_HOME
unset FM_NOTIFY_RECIPIENT
# A user's curl tracing defaults must not expose the producer credential.
printf 'trace-ascii = -\n' > "$HOME/.curlrc"
cli=$ROOT/bin/fm-notify-me.sh
id=11111111-2222-3333-4444-555555555555
args=(post --producer firstmate --dedupe test --title $'Quote " and newline\n' --body 'Plain body' --severity warning --link https://example.org/review --action 'approve:Approve: now' --action reject:Reject)
"$cli" "${args[@]}" > "$work/post-out" 2> "$work/post-err"
[[ $(<"$work/post-out") == "$id" ]]
if grep -q fixture-token "$work/post-out" "$work/post-err"; then
  echo 'credential leaked through curl defaults' >&2; exit 1
fi
[[ -f $work/posted ]]
[[ $("$cli" "${args[@]}") == "$id" ]]
[[ -z $("$cli" decision "$id") ]]
touch "$work/decided"
"$cli" decision "$id" | jq -e '.actionId=="approve" and .note=="Go" and .decidedBy=="owner"' >/dev/null
reject() {
  local expected=$1; shift
  local status=0
  "$cli" "$@" > "$work/out" 2> "$work/err" || status=$?
  [[ $status == "$expected" ]] || { echo "unexpected exit $status (expected $expected)" >&2; exit 1; }
  ! grep -q fixture-token "$work/out" "$work/err"
}
reject 2 post --producer '../escape' --dedupe t --title t --body b
reject 2 post --producer firstmate --dedupe t --title t
reject 2 post --dedupe t --title t --body b
reject 2 post --producer firstmate --dedupe t --title t --body b --action a:A --action b:B --action c:C --action d:D
reject 2 post --producer firstmate --dedupe t --title t --body b --action a:A --action a:B
reject 2 post --producer firstmate --dedupe t --title t --body b --action malformed
reject 2 post --producer firstmate --dedupe t --title t --body b --severity typo
reject 2 decision "$id" --title unexpected
reject 2 decision "'$id'"
reject 2 post --unknown x
reject 1 post --producer firstmate --dedupe refused --title t --body b
reject 1 post --producer firstmate --dedupe bad-conflict --title t --body b
chmod 644 "$HOME/.local/share/cfw-scripts-private/notify-firstmate.token"
reject 1 "${args[@]}"
chmod 600 "$HOME/.local/share/cfw-scripts-private/notify-firstmate.token"
reject 1 post --producer missing --dedupe t --title t --body b
rm "$FM_HOME/config/notify-recipient"
reject 2 "${args[@]}"
FM_NOTIFY_RECIPIENT=fixture-owner "$cli" "${args[@]}" > "$work/override-out"
[[ $(<"$work/override-out") == "$id" ]]
"$cli" --help >/dev/null
"$cli" decision --help >/dev/null
printf 'ok - notify-me posts atomic actions, deduplicates, reads decisions, and refuses invalid input and unsafe credentials\n'
