#!/usr/bin/env bash
# Behavior tests for the opt-in home lease (config/home-lease): renewal from session start, a worker
# claim before launch, delivery that stops when the lease moves, and a step loop that writes only while
# its host holds the lease. Every case runs the real commands against the stand-in for Dev 5001 in
# tests/fm-task-fake-api, with the two lease tables added. With config/home-lease absent every path is
# unchanged; the older suites (fm-host, fm-task, fm-task-shadow) hold that claim.
# shellcheck disable=SC2016 # fixture children expand their own variables
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { printf 'skip - node is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'

TMP_ROOT=$(fm_test_tmproot fm-home-lease-hardening)
TOKEN="tok-$$-$RANDOM"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
chmod 600 "$TMP_ROOT/token"

node - "$ROOT/tests/fm-task-fake-api/schema.json" "$TMP_ROOT/schema.json" <<'JS'
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[2]));
s.fm_host = {ops:['list','get','create','patch'],u:[['hostId']],f:{hostId:{t:'s',m:128},sshAlias:{t:'s',n:1,m:128},fmVersion:{t:'s',n:1,m:64},toolsJson:{t:'s',n:1},lastHeartbeatAt:{t:'d',n:1},registeredAt:{t:'d',n:1},wakeQueueLength:{t:'i',n:1},liveWorkers:{t:'i',n:1}}};
s.fm_home_lease = {ops:['list','get','create','patch'],u:[['home','generation']],f:{home:{t:'s',m:64},generation:{t:'i'},hostId:{t:'s',m:128},takenAt:{t:'d'},heartbeatAt:{t:'d'},releasedAt:{t:'d',n:1}}};
fs.writeFileSync(process.argv[3], JSON.stringify(s));
JS
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP_ROOT/port" "$TMP_ROOT/schema.json" "$TOKEN" &
API_PID=$!
HOMES=()
cleanup() {
  local h
  kill "$API_PID" 2>/dev/null || true
  for h in "${HOMES[@]:-}"; do [ -z "$h" ] || FM_HOME="$h" "$ROOT/bin/fm-task-step-loop.sh" stop >/dev/null 2>&1 || true; done
  fm_test_cleanup
}
trap cleanup EXIT
for ((i = 0; i < 100; i++)); do [ ! -s "$TMP_ROOT/port" ] || break; sleep 0.05; done
BASE="http://127.0.0.1:$(< "$TMP_ROOT/port")"
export FM_TASK_BASE_URL="$BASE" FM_TASK_TOKEN_FILE="$TMP_ROOT/token"

LEASE_HOME=fm-probe-lease
db() { curl -s "$BASE/__x/rows/$1"; }
api() { curl -s -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }
lease_row() { db fm_home_lease | jq -c --arg h "$LEASE_HOME" '[.[] | select(.home == $h)] | sort_by(.generation) | last'; }
reset_db() { curl -s -X POST "$BASE/__x/reset" >/dev/null; }

# A probe home with the lease on and its own host id. Echoes the home path.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$LEASE_HOME" > "$home/config/home-lease"
  HOMES+=("$home")
  printf '%s\n' "$home"
}

# A session stand-in: a process whose name the session lock accepts as a harness, kept alive for <seconds>.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
session() {  # <home> <host-id> <seconds> <log>: run fm-lock.sh in a live session process, in the background
  local home=$1 host=$2 seconds=$3 log=$4
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$home" FM_HOST_ID="$host" FM_HOST_HEARTBEAT_EVERY=1 FM_TASK_STEP_EVERY=1 \
    "$FAKEBIN/claude" -c "'$ROOT/bin/fm-lock.sh' > '$log' 2>&1; sleep $seconds" > /dev/null 2>&1 &
  SESSION_PID=$!
}
stop_loop() { FM_HOME="$1" "$ROOT/bin/fm-task-step-loop.sh" stop >/dev/null 2>&1 || true; }

# A first turn longer than 180 s must not lose the lease: the session renews it from session start, before any
# watcher is armed. The case reads the lease's heartbeat after the take and waits for it to move with nothing armed.
test_session_start_renews_the_lease_without_a_watcher() {
  reset_db
  local home first later i
  home=$(make_home renew)
  session "$home" probe-a 30 "$TMP_ROOT/renew.log"
  for ((i = 0; i < 100; i++)); do grep -q 'lock acquired' "$TMP_ROOT/renew.log" 2>/dev/null && break; sleep 0.1; done
  grep -q 'lock acquired' "$TMP_ROOT/renew.log" || { echo "session start did not finish: $(cat "$TMP_ROOT/renew.log")"; return 1; }
  first=$(lease_row | jq -r .heartbeatAt)
  [ "$(lease_row | jq -r .hostId)" = probe-a ] || { echo "the session did not take the lease: $(lease_row)"; return 1; }
  for ((i = 0; i < 100; i++)); do
    later=$(lease_row | jq -r .heartbeatAt)
    [ "$later" = "$first" ] || break
    sleep 0.1
  done
  stop_loop "$home"
  kill "$SESSION_PID" 2>/dev/null
  [ "$later" != "$first" ] || { echo "the lease heartbeat stayed at $first with no watcher armed"; return 1; }
  [ ! -e "$home/state/.arm" ] || { echo 'the case armed a watcher'; return 1; }
}

run_case() {
  local name=$1
  if "$name"; then pass "$name"; else fail "$name"; fi
}

run_case test_session_start_renews_the_lease_without_a_watcher
