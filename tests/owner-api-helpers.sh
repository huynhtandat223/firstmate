#!/usr/bin/env bash
# Controlled HTTP owner persistence for legacy public CLI suites.
owner_api_start() {
  local root=$1 temp=$2
  python3 - "$temp/owner-schema.json" <<'PY'
import json,sys
spec={}
for name,keys,fields in [('fm_owner_note',[['noteId']],['home','noteId','text','source','state','reply','at','requestId','announcedAt','handledAt','replyAt','replySeq']),('fm_home',[['home']],['home','posture','postureWords','postureSince']),('fm_hold_record',[['home','kind','sourceId']],['home','kind','sourceId','taskId','payload','state','at'])]:
 spec[name]={'ops':['list','get','create','patch'],'u':keys,'f':{k:{'t':'i' if k=='replySeq' else 's','n':1} for k in fields}}
open(sys.argv[1],'w').write(json.dumps(spec))
PY
  printf 'owner-test-token\n' > "$temp/owner-token"
  chmod 600 "$temp/owner-token"
  node "$root/tests/fm-task-fake-api/server.mjs" "$temp/owner-port" "$temp/owner-schema.json" owner-test-token &
  OWNER_API_PID=$!
  local attempt
  for attempt in $(seq 1 100); do [ ! -s "$temp/owner-port" ] || break; sleep 0.1; done
  FM_TASK_BASE_URL="http://127.0.0.1:$(< "$temp/owner-port")"
  FM_TASK_TOKEN_FILE="$temp/owner-token"
  export FM_TASK_BASE_URL FM_TASK_TOKEN_FILE
}
