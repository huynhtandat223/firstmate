#!/usr/bin/env bash
# Assistance authority, durable proposal/hold and context-rotation boundaries.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-assistance)
parent="$TMP_ROOT/parent"
helper="$TMP_ROOT/helper"
mkdir -p "$parent"/{data,state,config} "$helper"/{data,state,config}
export FM_HOME="$parent"
# Mutation proofs must never reach a real session when a target guard is removed.
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 99\n' > "$TMP_ROOT/fakebin/herdr"
chmod +x "$TMP_ROOT/fakebin/herdr"
export PATH="$TMP_ROOT/fakebin:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
cp "$ROOT/.tasks.toml" "$parent/.tasks.toml"
printf 'sample\n' > "$helper/.fm-assistance-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$helper/.fm-assistance-parent"
printf -- '- sample - Sample observer (home: %s; scope: observe; projects: ; added 2026-10-13)\n' "$helper" > "$parent/data/assistances.md"

refused() {
  local out
  if out=$("$@" 2>&1); then fail 'assistance operation unexpectedly succeeded'; fi
  [[ "$out" == *'assistance rule'* ]] || fail "missing assistance-rule explanation: $out"
}
refused env FM_HOME="$helper" "$ROOT/bin/fm-spawn.sh" accidental --scout
refused env FM_HOME="$helper" "$ROOT/bin/fm-send.sh" arbitrary 'steer'
pass 'assistance home refuses public spawn and steer before target resolution'
(
  cd "$helper"
  refused env FM_HOME=. "$ROOT/bin/fm-spawn.sh" accidental --scout
  refused env FM_HOME="$parent" "$ROOT/bin/fm-spawn.sh" accidental --scout
  refused env FM_HOME="$parent" "$ROOT/bin/fm-send.sh" arbitrary 'steer'
)
pass 'changing FM_HOME does not bypass assistance cwd boundary'
printf 'kind=assistance\nharness=claude\nbackend=herdr\nwindow=fixture:pane\n' > "$parent/state/sample.meta"
refused "$ROOT/bin/fm-send.sh" sample 'steer'
refused "$ROOT/bin/fm-control.sh" sample exit
refused "$ROOT/bin/fm-teardown.sh" sample
pass 'parent cannot steer, stop or remove assistance through ordinary worker commands'
refused env PI_CODING_AGENT=true "$ROOT/bin/fm-assistance.sh" stop sample --captain
refused env PI_CODING_AGENT=true "$ROOT/bin/fm-assistance.sh" stop sample --captain --captain-words '   '
[ ! -e "$parent/data/assistance-authority.jsonl" ] || fail 'refused authority wrote a receipt'
refused env FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" stop sample --captain --captain-words 'Stop sample.'
pass 'agent stop requires nonblank words and assistance cannot authorize itself'
for text in /exit "\$skill"; do
  refused "$ROOT/bin/fm-send.sh" sample --assistance-captain-words 'Tell sample this.' "$text"
done
refused "$ROOT/bin/fm-send.sh" sample --assistance-captain-words 'Press a key.' --key Enter
[ ! -e "$parent/data/assistance-authority.jsonl" ] || fail 'parser-native refusal wrote parent authority'
[ ! -e "$helper/data/assistance-authority.jsonl" ] || fail 'parser-native refusal wrote home authority'
[ ! -e "$parent/state/sample.inbox" ] || fail 'parser-native refusal wrote inbox'
pass 'authorized assistance send still refuses parser-native text and keys without receipts'
"$ROOT/bin/fm-assistance.sh" recover
pass 'disabled assistance is not restarted'
# Isolated dispatch adapter: no real backend lifecycle or endpoint is reached.
lab="$TMP_ROOT/dispatch-lab"
mkdir -p "$lab/bin"
cp "$ROOT"/bin/*.sh "$lab/bin/"
# shellcheck disable=SC2016
printf 'fm_meta_get() { grep "^$2=" "$1" | cut -d= -f2-; }\nfm_backend_agent_state() { if [ -f "$FM_HOME/state/fixture-dead" ]; then echo dead; else echo alive; fi; }\nfm_backend_of_meta() { echo fixture; }\nfm_backend_target_of_meta() { echo fixture; }\nfm_backend_send_text_submit() { echo ring >> "$FM_HOME/state/rings"; }\n' > "$lab/bin/fm-backend.sh"
mkdir -p "$parent/config/assistances"
jq -n '{name:"sample",harness:"claude",model:"test",effort:"medium",charter:"Observe",sources:[],trigger_mode:"event-driven"}' > "$parent/config/assistances/sample.json"
printf '{"old":true}\n' > "$helper/data/assistance.json"
cp "$helper/data/assistance.json" "$TMP_ROOT/installed.json"
if "$lab/bin/fm-assistance.sh" start sample > "$TMP_ROOT/attach.out" 2>&1; then fail 'live profile change accepted'; fi
grep -q 'profile changed; stop then start' "$TMP_ROOT/attach.out" || fail 'profile change lacked restart instruction'
cmp "$helper/data/assistance.json" "$TMP_ROOT/installed.json" || fail 'refusal changed profile'
cp "$parent/config/assistances/sample.json" "$helper/data/assistance.json"
"$lab/bin/fm-assistance.sh" start sample
jq -e '.trigger_mode == "event-driven"' "$helper/data/assistance.json" >/dev/null || fail 'live attach retained old profile'
printf 'home=%s\n' "$helper" >> "$parent/state/sample.meta"
printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/bin/fm-spawn.sh"
mkdir -p "$helper/state/procevent"
FM_HOME="$helper" "$ROOT/bin/fm-procevent.sh" register assistance-cadence assistance-cadence -- "$ROOT/bin/fm-procevent-assistance-cadence.sh" wait >/dev/null
jq '.charter="New charter"' "$parent/config/assistances/sample.json" > "$TMP_ROOT/new-profile.json"
cp "$TMP_ROOT/new-profile.json" "$parent/config/assistances/sample.json"
touch "$parent/state/fixture-dead"
touch "$TMP_ROOT/authority-target"
ln -s "$TMP_ROOT/authority-target" "$parent/data/assistance-authority.jsonl"
if "$lab/bin/fm-assistance.sh" stop sample --captain --captain-words 'Stop sample.' > "$TMP_ROOT/refused-stop.out" 2>&1; then fail 'symlink authority accepted'; fi
[ -f "$helper/state/procevent/assistance-cadence.source" ] || fail 'authority refusal retired cadence'
[ -f "$helper/config/assistance-enabled" ] || fail 'authority refusal disabled assistance'
rm "$parent/data/assistance-authority.jsonl"
"$lab/bin/fm-assistance.sh" stop sample --captain --captain-words 'Stop sample.'
[ ! -e "$helper/state/procevent/assistance-cadence.source" ] || fail 'stop retained cadence registration'
"$lab/bin/fm-assistance.sh" start sample
cmp "$parent/config/assistances/sample.json" "$helper/data/assistance.json" || fail 'restart retained old profile'
grep -qx 'New charter' "$helper/data/charter.md" || fail 'restart retained old charter'
grep -qx '# Assistance role' "$helper/data/charter.md" || fail 'restart lost assistance role'
grep -qx 'Run no fleet startup, dispatch, steering, merge, or project mutation.' "$helper/data/charter.md" || fail 'restart lost role boundaries'
rm "$parent/state/fixture-dead"
rm -f "$parent/data/assistance-authority.jsonl" "$helper/data/assistance-authority.jsonl"
mkdir -p "$parent/config/assistances"
jq -n '{name:"sample",harness:"claude",model:"test",effort:"medium",charter:"Observe",sources:[],trigger_mode:"event-driven"}' > "$parent/config/assistances/sample.json"
"$ROOT/bin/fm-assistance.sh" validate sample
jq '.trigger_mode="cadence" | .cadence_seconds=900' "$parent/config/assistances/sample.json" > "$TMP_ROOT/profile.json"
cp "$TMP_ROOT/profile.json" "$parent/config/assistances/sample.json"
"$ROOT/bin/fm-assistance.sh" validate sample
mkdir -p "$helper/data/pending-mentions"
printf '{"schema":"fm-assistance-mentions.v1","messages":[{"id":"one","arrival":1,"content":"Observe this"}]}\n' > "$helper/data/pending-mentions/one.json"
if "$ROOT/bin/fm-assistance.sh" source-event sample one.json; then fail 'mismatched content basename accepted'; fi
record=$(jq -c '.messages | map([.id,.arrival])' "$helper/data/pending-mentions/one.json" | sha256sum | cut -d' ' -f1).json
mv "$helper/data/pending-mentions/one.json" "$helper/data/pending-mentions/$record"
"$ROOT/bin/fm-assistance.sh" source-event sample "$record"
"$ROOT/bin/fm-assistance.sh" source-event sample "$record"
[ "$(find "$parent/state/sample.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] || fail 'source event duplicated'
grep -q 'fm-assistance-source.v1' "$parent/state/sample.inbox/001.msg" || fail 'source type missing'
if "$ROOT/bin/fm-assistance.sh" steer sample --captain-words 'Owner instruction' "$(<"$helper/data/pending-mentions/$record")"; then fail 'source record accepted as captain words'; fi
[ ! -e "$parent/data/assistance-authority.jsonl" ] || fail 'source event granted authority'
[ -f "$helper/data/pending-mentions/$record" ] || fail 'delivery deleted pending evidence'
if FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" acknowledge-source "$record"; then fail 'ack accepted before inbox acknowledgement'; fi
mv "$parent/state/sample.inbox/001.msg" "$parent/state/sample.inbox/handled/001.msg"
cp "$helper/data/pending-mentions/$record" "$TMP_ROOT/original-pending.json"
jq '.messages[0].id="changed"' "$TMP_ROOT/original-pending.json" > "$helper/data/pending-mentions/$record"
if FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" acknowledge-source "$record"; then fail 'ack accepted mutated identity'; fi
[ -f "$helper/data/pending-mentions/$record" ] || fail 'refused ack deleted evidence'
cp "$TMP_ROOT/original-pending.json" "$helper/data/pending-mentions/$record"
FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" acknowledge-source "$record"
if FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" acknowledge-source "$record"; then fail 'missing pending ack succeeded'; fi
cp "$TMP_ROOT/original-pending.json" "$helper/data/pending-mentions/$record"
"$lab/bin/fm-assistance.sh" source-event sample "$record"
[ ! -e "$parent/state/rings" ] || fail 'handled replay rang old source'
[ ! -e "$helper/data/pending-mentions/$record" ] || fail 'handled replay retained pending evidence'
pass 'event profile, cadence compatibility and authority-free idempotent source delivery'
cp "$parent/data/assistances.md" "$TMP_ROOT/registry"
for name in missing-one missing-two; do
  mkdir -p "$TMP_ROOT/$name/config"
  touch "$TMP_ROOT/$name/config/assistance-enabled"
  printf -- '- %s - Missing profile (home: %s; scope: observe; projects: ; added 2026-10-13)\n' "$name" "$TMP_ROOT/$name" >> "$parent/data/assistances.md"
done
if "$ROOT/bin/fm-assistance.sh" recover > "$TMP_ROOT/recover.out" 2>&1; then fail 'recovery hid unavailable profiles'; fi
for name in missing-one missing-two; do
  grep -q "$name.json" "$TMP_ROOT/recover.out" || fail "recovery skipped $name after another failure"
done
cp "$TMP_ROOT/registry" "$parent/data/assistances.md"
pass 'one recovery refusal does not suppress later enabled assistances'
mkdir -p "$parent/config/assistances"
printf '{"name":"unsupported","harness":"pi"}\n' > "$parent/config/assistances/unsupported.json"
if "$ROOT/bin/fm-assistance.sh" start unsupported > "$TMP_ROOT/unsupported.out" 2>&1; then fail 'unsupported rotation harness was accepted'; fi
grep -q 'only Claude self-rotation is supported' "$TMP_ROOT/unsupported.out" || fail 'unsupported harness lacked explanation'
other="$TMP_ROOT/other"
mkdir -p "$other/bin"
printf 'project\n' > "$other/AGENTS.md"
printf 'other\n' > "$other/.fm-secondmate-home"
refused "$ROOT/bin/fm-home-seed.sh" --assistance other "$other" --no-projects
[ -f "$other/.fm-secondmate-home" ] || fail 'kind refusal damaged secondmate identity'
pass 'assistance seed refuses a secondmate home and preserves its identity'

cp "$helper/.fm-assistance-parent" "$TMP_ROOT/parent-binding"
printf 'parent_home=%s\n' "$parent" >> "$helper/.fm-assistance-parent"
if FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" propose bad bad bad > "$TMP_ROOT/binding.out" 2>&1; then fail 'ambiguous parent binding was accepted'; fi
[ ! -e "$parent/state/inbox" ] || fail 'invalid binding wrote a proposal'
cp "$TMP_ROOT/parent-binding" "$helper/.fm-assistance-parent"
pass 'proposal uses the shared parent-binding validation'

FM_HOME="$helper" "$ROOT/bin/fm-assistance.sh" propose 'Inspect new report' 'New information needs a decision' 'https://example.test/report' > "$TMP_ROOT/proposal.out"
[ "$(find "$parent/state/inbox" -name '*.note' | wc -l | tr -d ' ')" = 1 ] || fail 'proposal was not delivered once'
[ "$(wc -l < "$parent/state/.wake-queue" | tr -d ' ')" = 1 ] || fail 'proposal did not produce exactly one wake'
note=$(find "$parent/state/inbox" -name '*.note')
id=${note##*/}; id=${id%.note}
"$ROOT/bin/fm-assistance.sh" record "$id" > "$TMP_ROOT/record.out"
"$ROOT/bin/fm-tasks-axi.sh" show "proposal-$id" --full > "$TMP_ROOT/task.out"
grep -q '^  held: yes$' "$TMP_ROOT/task.out" || fail 'proposal was not held for the captain'
"$ROOT/bin/fm-fleet-snapshot.sh" --json --records-only > "$TMP_ROOT/board.json"
jq -e --arg id "proposal-$id" '.backlog.records[] | select(.id == $id and .hold_kind == "captain" and .captain_actionable == true)' "$TMP_ROOT/board.json" >/dev/null || fail 'held item is not actionable on the board'
[ -f "$parent/state/inbox/handled/$id.note" ] || fail 'recorded proposal was not acknowledged'
[ ! -e "$parent/data/secondmates.md" ] || fail 'proposal altered secondmate registry'
pass 'real inbox wake becomes a real held backlog item, without a secondmate route'

printf '{"session_id":"first"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" start >/dev/null
FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" settings | jq -e '.hooks.Stop[0].hooks[1].asyncRewake == true' >/dev/null
printf '{"session_id":"first","context_window":{"context_window_size":100000,"used_percentage":39}}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" usage >/dev/null
printf '{"session_id":"first"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" stop
[ ! -e "$helper/state/assistance-rotation.json" ] || fail 'rotation below 40 percent'
printf '{"session_id":"first","context_window":{"context_window_size":100000,"used_percentage":40}}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" usage >/dev/null
set +e
printf '{"session_id":"first"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" stop > "$TMP_ROOT/stop.out" 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail '40 percent did not force stow continuation'
jq -e '.session == "first"' "$helper/state/assistance-rotation.json" >/dev/null
if FM_HOME="$helper" "$ROOT/bin/fm-assistance-rotate.sh" > "$TMP_ROOT/rotate.out" 2>&1; then fail 'rotation accepted missing stow/handoff'; fi
grep -q 'missing ordinary assistance-stow.md' "$TMP_ROOT/rotate.out" || fail 'rotation refusal did not name missing stow'
pass 'actual hooks request self-stow at 40 percent and refuse rotation without its artifacts'
printf '{"session_id":"first"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" start >/dev/null
[ -f "$helper/state/assistance-rotation.json" ] || fail 'resuming the same session discarded its rotation request'
printf '{"session_id":"recovered"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" start >/dev/null
[ ! -e "$helper/state/assistance-rotation.json" ] || fail 'new session retained a stale rotation request'
printf '{"trigger_mode":"event-driven"}\n' > "$helper/data/assistance.json"
printf '{"session_id":"recovered"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" cadence
[ ! -e "$helper/state/procevent-inbox/assistance-cadence.1.result" ] || fail 'event home scheduled cadence'
printf '{"cadence_seconds":1}\n' > "$helper/data/assistance.json"
set +e
printf '{"session_id":"recovered"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" cadence > "$TMP_ROOT/cadence.out" 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail 'recovered session did not schedule a cadence wake'
grep -q 'Assistance cadence:' "$TMP_ROOT/cadence.out" || fail 'cadence did not request continuation'
[ -f "$helper/state/procevent-inbox/assistance-cadence.1.result" ] || fail 'recovered cadence produced no durable result'
printf '{"session_id":"recovered","context_window":{"context_window_size":100000,"used_percentage":40}}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" usage >/dev/null
set +e
printf '{"session_id":"recovered"}\n' | FM_HOME="$helper" "$ROOT/bin/fm-assistance-hook.sh" stop > "$TMP_ROOT/recovered-stop.out" 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail 'recovered session did not request rotation at 40 percent'
jq -e '.session == "recovered"' "$helper/state/assistance-rotation.json" >/dev/null || fail 'rotation request was not rebound to the recovered session'
pass 'new session clears stale rotation, schedules cadence and creates its own 40-percent request'
# The registry is deliberately populated, but secondmate routing cannot use it.
if "$ROOT/bin/fm-backlog-handoff.sh" sample "proposal-$id" > "$TMP_ROOT/handoff.out" 2>&1; then fail 'secondmate handoff adopted an assistance'; fi
"$ROOT/bin/fm-tasks-axi.sh" show "proposal-$id" >/dev/null || fail 'refused handoff moved the proposal'
pass 'secondmate handoff ignores the assistance registry'
