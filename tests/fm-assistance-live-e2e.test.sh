#!/usr/bin/env bash
# Opt-in real Claude/Herdr assistance lifecycle and self-rotation proof.
# All Herdr calls (including production adapters) cross the isolated lab helper.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_ASSISTANCE_LIVE_E2E git herdr jq claude tasks-axi
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-assistance)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-assistance-live.XXXXXX")
ORIGINAL_PATH=$PATH
code="$TMP_ROOT/code"
parent="$TMP_ROOT/parent"
helper="$TMP_ROOT/helper"
shim="$TMP_ROOT/shim"
cleanup() {
  rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  printf 'evidence: scratch=%s exit=%s\n' "$TMP_ROOT" "$rc"
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$parent"/{data/sample,state,config/assistances,projects} "$shim"
git clone -q --no-hardlinks "$ROOT" "$code"
# Exercise this uncommitted artifact too; the final PR pins the committed head.
cp -a "$ROOT/bin/." "$code/bin/"
cp "$ROOT/.tasks.toml" "$parent/.tasks.toml"
cat > "$shim/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
fi
PATH='$ORIGINAL_PATH' exec '$LAB_HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$shim/herdr"
export PATH="$shim:$ORIGINAL_PATH" HERDR_SESSION="$SESSION"
export FM_HOME="$parent" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
printf 'FM_BACKEND_HERDR_BIN\nFM_BACKEND_HERDR_CLIENT_SESSION\n' > "$parent/config/launch-env-allowlist"
export FM_BACKEND_HERDR_BIN="$shim/herdr" FM_BACKEND_HERDR_CLIENT_SESSION="$SESSION"
cat > "$parent/data/sample/brief.md" <<'EOF'
# Assistance role
You are an assistance in an isolated verification home, not a supervisor.
Follow this role instead of AGENTS.md's supervisor identity.
# Charter
If data/ready.txt already exists, read the handoff when present and finish without another proposal.
Otherwise read data/source.txt, then send exactly one proposal with bin/fm-assistance.sh propose 'Sample source needs review' 'The source has new evidence' data/source.txt.
Attempt bin/fm-spawn.sh accidental --scout, save its refusal to data/spawn-refusal.txt, then write data/ready.txt and finish your turn.
When the context hook asks, stow into data/assistance-stow.md, write data/assistance-handoff.md with ## Suggested skills and ## Next action, and run bin/fm-assistance-rotate.sh.
On an assistance cadence notification, acknowledge the process-event result with bin/fm-procevent.sh handled assistance-cadence <sequence>, write data/cadence.txt and finish the turn without another proposal.
The handoff Next action must tell the fresh session to write data/continued.txt and do nothing else.
# Routing scope
Observe and propose only.
# Project clones
None. This is a project-less domain.
EOF
PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$SESSION"
PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" status --json | jq -r '"evidence: Herdr " + .client.version'
claude --version
"$code/bin/fm-home-seed.sh" --assistance sample "$helper" --no-projects > "$TMP_ROOT/seed.log"
cp -a "$code/bin/." "$helper/bin/"
printf 'New evidence in an isolated test source.\n' > "$helper/data/source.txt"
jq -n '{name:"sample",charter:"Read the sample source only.",harness:"claude",model:"sonnet",effort:"low",sources:[{source:"data/source.txt",recipe:"read"}],cadence_seconds:5}' > "$parent/config/assistances/sample.json"
"$code/bin/fm-assistance.sh" start sample | tee "$TMP_ROOT/start.log"
meta="$parent/state/sample.meta"
target=$(awk -F= '$1=="window" {print substr($0,8)}' "$meta")
pane=${target#*:}
for ((n=0;n<180;n++)); do
  [ -f "$helper/data/ready.txt" ] && break
  sleep 1
done
if [ ! -f "$helper/data/ready.txt" ]; then
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane capture "$pane" --lines 60 || true
  fail 'real assistance did not finish source/proposal/refusal proof'
fi
grep -q 'assistance rule' "$helper/data/spawn-refusal.txt" || fail 'real spawn was not refused'
note=$(find "$parent/state/inbox" -maxdepth 1 -name '*.note' | head -1)
[ -n "$note" ] || fail 'real proposal missing'
id=${note##*/}; id=${id%.note}
"$code/bin/fm-assistance.sh" record "$id"
"$code/bin/fm-fleet-snapshot.sh" --json --records-only > "$TMP_ROOT/board.json"
jq -e --arg id "proposal-$id" '.backlog.records[] | select(.id == $id and .hold_kind == "captain" and .captain_actionable == true)' "$TMP_ROOT/board.json" >/dev/null || fail 'held proposal absent from board snapshot'
"$code/bin/fm-assistance.sh" start sample | grep 'attached:'
pass 'real assistance start, proposal, held board item, spawn refusal and repeated start'
for ((n=0;n<60;n++)); do
  [ -f "$helper/data/cadence.txt" ] && break
  sleep 1
done
[ -f "$helper/data/cadence.txt" ] || fail 'real cadence did not awaken the assistance'
pass 'registered process-event cadence wakes the real assistance'
# Force the accepted threshold through the real hook, not a parent handoff.
session=$(<"$helper/state/assistance-session")
jq -n --arg session "$session" '{session_id:$session,context_window:{context_window_size:100000,used_percentage:40}}' |
  FM_HOME="$helper" "$code/bin/fm-assistance-hook.sh" usage >/dev/null
set +e
jq -n --arg session "$session" '{session_id:$session}' | FM_HOME="$helper" "$code/bin/fm-assistance-hook.sh" stop > "$TMP_ROOT/threshold.log" 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail 'forced threshold did not request self-stow'
PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane run "$pane" "$(<"$TMP_ROOT/threshold.log")" >/dev/null
for ((n=0;n<180;n++)); do
  [ -f "$helper/data/continued.txt" ] && break
  sleep 1
done
[ -f "$helper/data/continued.txt" ] || fail 'fresh session did not continue'
[ "$(<"$helper/state/assistance-session")" != "$session" ] || fail 'continuation used the old context'
[ -s "$helper/data/assistance-stow.md" ] && [ -s "$helper/data/assistance-handoff.md" ] || fail 'rotation lost artifacts'
pass 'forced 40-percent request produced stow, handoff and a fresh continuing Claude session'
# Simulate process loss while enabled, then use the same recovery entry as startup.
# shellcheck source=bin/fm-backend.sh
. "$code/bin/fm-backend.sh"
before=$(<"$helper/state/assistance-session")
PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane run "$pane" /exit >/dev/null
for ((n=0;n<30;n++)); do
  [ "$(fm_backend_agent_state herdr "$target")" = dead ] && break
  sleep 1
done
"$code/bin/fm-assistance.sh" recover
for ((n=0;n<30;n++)); do
  [ "$(<"$helper/state/assistance-session")" != "$before" ] && break
  sleep 1
done
[ "$(<"$helper/state/assistance-session")" != "$before" ] || fail 'enabled assistance was not recovered'
target=$(fm_backend_target_of_meta "$meta")
for ((n=0;n<30;n++)); do
  if [ "$(fm_backend_agent_state herdr "$target")" = alive ] && [ "$(fm_backend_busy_state herdr "$target")" = idle ]; then break; fi
  sleep 1
done
[ "$(fm_backend_agent_state herdr "$target")" = alive ] || fail 'recovered process was not attributable'
pass 'startup recovery relaunched the enabled assistance after process loss'
if "$code/bin/fm-assistance.sh" stop sample --captain > "$TMP_ROOT/refused-stop.log" 2>&1; then fail 'agent stop without words succeeded'; fi
grep -q 'verbatim instruction' "$TMP_ROOT/refused-stop.log" || fail 'missing authority refusal'
[ -f "$helper/config/assistance-enabled" ] || fail 'refused stop disabled recovery'
words='Stop the sample assistance now.'
"$code/bin/fm-assistance.sh" stop sample --captain --captain-words "$words" | tee "$TMP_ROOT/authorized-stop.log"
jq -e --arg words "$words" 'select(.name == "sample" and .action == "stop" and .words == $words)' "$parent/data/assistance-authority.jsonl" >/dev/null || fail 'verbatim stop authority missing'
[ ! -e "$helper/config/assistance-enabled" ] || fail 'authorized stop left restart enabled'
"$code/bin/fm-assistance.sh" start sample
target=$(fm_backend_target_of_meta "$meta")
for ((n=0;n<30;n++)); do
  [ "$(fm_backend_agent_state herdr "$target")" = alive ] && break
  sleep 1
done
[ "$(fm_backend_agent_state herdr "$target")" = alive ] || fail 'human-stop test requires a live assistance'
pass 'agent stop refuses absent words and records explicit words before stopping'
# A separate shell in the owned lab models the captain terminal, not firstmate.
# Lab teardown is always the final safety net; it never touches default.
terminal=$(PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" tab create --cwd "$parent" --label captain-stop --no-focus | jq -er '.result.root_pane.pane_id')
printf -v stop_command 'env -i HOME=%q PATH=%q FM_HOME=%q FM_BACKEND_HERDR_BIN=%q FM_BACKEND_HERDR_CLIENT_SESSION=%q bash %q stop sample --captain > %q 2>&1; echo $? > %q' "$HOME" "$PATH" "$parent" "$shim/herdr" "$SESSION" "$code/bin/fm-assistance.sh" "$TMP_ROOT/stop.log" "$TMP_ROOT/stop.rc"
PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane run "$terminal" "$stop_command" >/dev/null
for ((n=0;n<40;n++)); do
  [ -f "$TMP_ROOT/stop.rc" ] && break
  sleep 1
done
[ -f "$TMP_ROOT/stop.rc" ] && [ "$(<"$TMP_ROOT/stop.rc")" = 0 ] || fail 'captain-terminal stop did not succeed'
[ ! -e "$helper/config/assistance-enabled" ] || fail 'captain stop left restart enabled'
cat "$TMP_ROOT/stop.log"
pass 'captain command stopped assistance and disabled restart; home retained'
