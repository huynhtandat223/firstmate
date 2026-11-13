#!/usr/bin/env bash
# Public CLI proof against the task API fixture. Real Dev 5001 proof is separately required.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
PID=
trap 'test -z "$PID" || kill "$PID"; rm -rf "$TMP"' EXIT
printf 'ledger-test\n' > "$TMP/token"
chmod 600 "$TMP/token"
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP/port" "$ROOT/tests/fm-task-fake-api/schema.json" ledger-test > "$TMP/server.log" 2>&1 &
PID=$!
for ((i=0; i<100; i++)); do [ ! -s "$TMP/port" ] || break; sleep 0.05; done
export FM_TASK_BASE_URL="http://127.0.0.1:$(<"$TMP/port")" FM_TASK_TOKEN_FILE="$TMP/token" FM_HOME="$TMP/home"
mkdir -p "$FM_HOME/config"
call() { bash "$ROOT/bin/fm-task.sh" deploy-ledger "$@"; }
printf '%s\n' '{"type":"deployed","sha":"abc","run":"https://example.test/run/1"}' '{"type":"ask","task":"probe","round":"deploy","sha":"abc","rows":["DV1@-"],"tester":"tester"}' '{"type":"hold","task":"probe","sha":"abc","at":1}' '{"type":"hold","task":"probe","sha":"abc","at":2}' > "$TMP/seed"
call seed --file "$TMP/seed"
call seed --file "$TMP/seed"
call list > "$TMP/read"
jq -s -e 'length == 4 and .[1].rows == ["DV1@-"] and .[2].at == 1 and .[3].at == 2' "$TMP/read" >/dev/null
printf '{"cursor_run":123,"last_green_sha":"abc"}\n' > "$TMP/cursor"
call put-cursor --file "$TMP/cursor"
call cursor | jq -e '.cursor_run == 123 and .last_green_sha == "abc" and (has("type") | not)' >/dev/null
# The gate's supported shared-history read must work with no legacy ledger file.
bash -c '. "$1/bin/fm-verify-gate-lib.sh"; fm_verify_gate_ledger_shas /absent/ledger.jsonl probe' _ "$ROOT" > "$TMP/heads"
[ "$(<"$TMP/heads")" = abc ]
printf '{"type":"ask","task":"undeployed","round":"rows","sha":"not-deployed"}\n' > "$TMP/row"
call append --file "$TMP/row"
bash -c '. "$1/bin/fm-verify-gate-lib.sh"; fm_verify_gate_ledger_shas /absent/ledger.jsonl undeployed' _ "$ROOT" > "$TMP/heads"
[ ! -s "$TMP/heads" ]
# Independent CLI processes contend for the same repository position allocation.
RACE_PIDS=()
for ((i=0; i<12; i++)); do
  printf '{"type":"hold","task":"race-%s","at":%s}\n' "$i" "$i" > "$TMP/race-$i"
  call append --file "$TMP/race-$i" > "$TMP/race-$i.out" 2>&1 &
  RACE_PIDS+=("$!")
done
for child in "${RACE_PIDS[@]}"; do wait "$child"; done
call list > "$TMP/raced"
jq -s -e '[.[] | select((.task // "") | startswith("race-"))] | length == 12' "$TMP/raced" >/dev/null
export FM_TASK_BASE_URL=http://127.0.0.1:1
if call list > "$TMP/out" 2> "$TMP/error"; then echo 'outage was accepted' >&2; exit 1; fi
printf 'PASS deploy ledger lossless seed, retry, cursor, deployed-head filtering, and outage refusal\n'
