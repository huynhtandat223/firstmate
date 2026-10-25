#!/usr/bin/env bash
# Real writer integration for holds across lifecycle states and repeated occurrences.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-shadow-record)
trap 'kill "${PID:-0}" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$TMP_ROOT/home/config" "$TMP_ROOT/home/state" "$TMP_ROOT/home/data"
touch "$TMP_ROOT/home/config/task-shadow"
printf token > "$TMP_ROOT/token"; chmod 600 "$TMP_ROOT/token"
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP_ROOT/port" "$ROOT/tests/fm-task-fake-api/schema.json" token &
PID=$!
for _ in {1..100}; do [ ! -s "$TMP_ROOT/port" ] || break; sleep .1; done
FM_TASK_BASE_URL="http://127.0.0.1:$(<"$TMP_ROOT/port")"
export FM_HOME="$TMP_ROOT/home" FM_TASK_TOKEN_FILE="$TMP_ROOT/token" FM_TASK_BASE_URL
unset FM_TASK_AUTH
bash "$ROOT/bin/fm-task-shadow.sh" held missing captain 'Choose A'
"$ROOT/bin/fm-task.sh" show missing --json | jq -e '.state == "blocked" and .nextActor == "owner"'
"$ROOT/bin/fm-task.sh" create queued --title Q --kind ship
bash "$ROOT/bin/fm-task-shadow.sh" held queued captain 'Choose B'
"$ROOT/bin/fm-task.sh" show queued --json | jq -e '.state == "blocked" and .nextActor == "owner"'
bash "$ROOT/bin/fm-task-shadow.sh" dispatched fresh ship example/repo pi
"$ROOT/bin/fm-task.sh" show fresh --json | jq -e '.assignee == "fresh"'
bash "$ROOT/bin/fm-task-shadow.sh" held fresh external 'External dependency'
"$ROOT/bin/fm-task.sh" show fresh --json | jq -e '.blockKind == "external"'
printf '## Queued\n- [ ] mapped - Mapping probe (hold-kind: external) (hold: External dependency)\n' > "$FM_HOME/data/backlog.md"
bash "$ROOT/bin/fm-task-backfill.sh"
"$ROOT/bin/fm-task.sh" show mapped --json | jq -e '.blockKind == "external"'
bash "$ROOT/bin/fm-task-shadow.sh" held repeat captain 'Same reason' occurrence-1
"$ROOT/bin/fm-task.sh" unblock repeat
bash "$ROOT/bin/fm-task-shadow.sh" held repeat captain 'Same reason' occurrence-2
"$ROOT/bin/fm-task.sh" show repeat --json | jq -e '.state == "blocked" and .nextActor == "owner"'
"$ROOT/bin/fm-task.sh" import closed --title Closed --kind ship --state done --assignee closed --next-actor firstmate
"$ROOT/bin/fm-task.sh" reopen closed --reason 'New work' --key reopen-once
"$ROOT/bin/fm-task.sh" reopen closed --reason 'New work' --key reopen-once
"$ROOT/bin/fm-task.sh" show closed --json | jq -e '.state == "ready" and .nextActor == "firstmate"'
if "$ROOT/bin/fm-task.sh" reopen closed --reason again; then fail 'reopen allowed from ready'; fi
"$ROOT/bin/fm-task.sh" archive closed
if "$ROOT/bin/fm-task.sh" reopen closed --reason again; then fail 'reopen allowed from archived'; fi
bash "$ROOT/bin/fm-task-shadow.sh" held closing captain 'Close this'
bash "$ROOT/bin/fm-task-shadow.sh" answered closing closed
"$ROOT/bin/fm-task.sh" show closing --json | jq -e '.state == "done"'
"$ROOT/bin/fm-task.sh" create readywork --title Ready --kind ship
"$ROOT/bin/fm-task.sh" assign readywork --to readywork
printf 'working [at=123]: work\n' > "$FM_HOME/state/readywork.status"
bash "$ROOT/bin/fm-task-shadow.sh" status "$FM_HOME/config" "$FM_HOME/state/readywork.status"
"$ROOT/bin/fm-task.sh" show readywork --json | jq -e '.state == "running"'
bash "$ROOT/bin/fm-task-shadow.sh" held verify external 'verification pending: A1 waits'
"$ROOT/bin/fm-task.sh" show verify --json | jq -e '.state == "review" and .nextActor == "tester"'
echo 'ok - shadow lifecycle and explicit reopen'
