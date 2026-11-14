#!/usr/bin/env bash
# Exercise the public cleanup command; isolated API avoids destructive real task fixtures.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-clean-artifacts)
trap 'kill "${PID:-0}" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/home/state"
printf token > "$TMP_ROOT/token"; chmod 600 "$TMP_ROOT/token"
node - "$ROOT/tests/fm-task-fake-api/schema.json" "$TMP_ROOT/schema.json" <<'JS'
const fs = require('fs');
const schema = JSON.parse(fs.readFileSync(process.argv[2]));
schema.fm_event_document = {ops:['list','get','create'],f:{title:{t:'s',m:200},mediaType:{t:'s',m:100},content:{t:'s'}},u:[],parent:['fmTaskEvent','documents']};
fs.writeFileSync(process.argv[3], JSON.stringify(schema));
JS
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP_ROOT/port" "$TMP_ROOT/schema.json" token &
PID=$!
for _ in {1..100}; do [ ! -s "$TMP_ROOT/port" ] || break; sleep .1; done
FM_TASK_BASE_URL="http://127.0.0.1:$(<"$TMP_ROOT/port")"
export FM_TASK_BASE_URL FM_TASK_TOKEN_FILE="$TMP_ROOT/token" FM_HOME="$TMP_ROOT/home"
for task in clean open unsafe dirty; do
  state='done'; [ "$task" != open ] || state=running
  "$ROOT/bin/fm-task.sh" import "$task" --title "$task" --kind other --state "$state" --assignee worker --next-actor firstmate >/dev/null
  mkdir -p "$FM_HOME/data/$task"
  printf 'unique original evidence %s\n' "$task" > "$FM_HOME/data/$task/evidence.txt"
done
mkdir -p "$FM_HOME/data/verify/clean"
printf verification > "$FM_HOME/data/verify/clean/proof"
ln -s "$TMP_ROOT" "$FM_HOME/data/unsafe/link"
git -C "$FM_HOME/data/dirty" init -q
python3 "$ROOT/bin/fm-clean-artifacts.py" --sweep > "$TMP_ROOT/dry"
test -f "$FM_HOME/data/clean/evidence.txt"
grep -q 'eligibleTasks: 1' "$TMP_ROOT/dry"
python3 "$ROOT/bin/fm-clean-artifacts.py" --sweep --apply > "$TMP_ROOT/apply"
test ! -e "$FM_HOME/data/clean"
test ! -e "$FM_HOME/data/verify/clean"
test -f "$FM_HOME/data/open/evidence.txt"
test -f "$FM_HOME/data/unsafe/evidence.txt"
test -f "$FM_HOME/data/dirty/evidence.txt"
archive=$(find "$FM_HOME/data/artifact-archives/clean" -name files.tar.gz)
mkdir "$TMP_ROOT/restored"
tar xzf "$archive" -C "$TMP_ROOT/restored"
grep -q 'unique original evidence clean' "$TMP_ROOT/restored/${FM_HOME#/}/data/clean/evidence.txt"
curl -fsS "$FM_TASK_BASE_URL/__x/rows/fm_event_document" | jq -e 'any(.[]; .title == "Artifact backup manifest" and (.content | contains("sha256")))' >/dev/null
# Sensitivity: remove only the safety guard in the isolated probe, then observe deletion.
rm "$FM_HOME/data/unsafe/link"
python3 "$ROOT/bin/fm-clean-artifacts.py" unsafe --apply >/dev/null
test ! -e "$FM_HOME/data/unsafe"
python3 "$ROOT/bin/fm-clean-artifacts.py" clean --apply > "$TMP_ROOT/retry"
grep -q 'eligibleTasks: 0' "$TMP_ROOT/retry"
printf 'PASS: dry run, selection, verified archive, attachment, guard sensitivity, retry\n'
