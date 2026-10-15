#!/usr/bin/env bash
# Assistance authority, durable proposal/hold and context-rotation boundaries.
# shellcheck disable=SC2016 # mutation proofs pass literal shell source lines as fixed strings
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

# --- workdir profile field and self-owned source delivery (issue 117) --------
# Guard proofs build a mutant copy of the bin directory with exactly one guard
# line replaced, then require the same input the real script refuses to be
# accepted. Backend calls hit the stub below, never a real session.
selflab="$TMP_ROOT/self-lab"
selfparent="$TMP_ROOT/self-parent"
selfhome="$TMP_ROOT/self-home"
project="$TMP_ROOT/project-workdir"
mkdir -p "$selflab/bin" "$selfparent"/{data,state,config/assistances} "$selfhome"/{data/pending-mentions,state,config} "$project"
cp "$ROOT"/bin/*.sh "$selflab/bin/"
# shellcheck disable=SC2016
printf 'fm_meta_get() { grep "^$2=" "$1" | cut -d= -f2-; }\nfm_backend_agent_state() { if [ -f "$FM_HOME/state/fixture-dead" ]; then echo dead; else echo alive; fi; }\nfm_backend_composer_state() { if [ -f "$FM_HOME/state/fixture-pending" ]; then echo pending; else echo empty; fi; }\nfm_backend_of_meta() { echo fixture; }\nfm_backend_target_of_meta() { echo fixture; }\nfm_backend_send_text_submit() { [ ! -f "$FM_HOME/state/fixture-slow" ] || sleep 1; printf "%%s\\n" "$3" >> "$FM_HOME/state/rings"; cat "$FM_HOME/state/fixture-verdict" 2>/dev/null || echo empty; }\n' > "$selflab/bin/fm-backend.sh"
printf 'self\n' > "$selfhome/.fm-assistance-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$selfparent" > "$selfhome/.fm-assistance-parent"
printf 'fixture:pane\n' > "$selfhome/state/assistance-endpoint"
printf -- '- self - Self observer (home: %s; scope: observe; projects: ; added 2026-10-15)\n' "$selfhome" > "$selfparent/data/assistances.md"

# mutate_line <dir> <file> <fixed-substring> <replacement>: replace the one line
# of <dir>/bin/<file> containing the substring; fails unless exactly one matched.
mutate_line() {
  local dir=$1 file=$2 pat=$3 rep=$4
  awk -v pat="$pat" -v rep="$rep" 'index($0, pat) { print rep; n++; next } { print } END { exit (n == 1 ? 0 : 1) }' "$dir/bin/$file" > "$dir/bin/$file.mut" || fail "mutation target not found exactly once: $pat"
  mv "$dir/bin/$file.mut" "$dir/bin/$file"
  chmod +x "$dir/bin/$file"
}
# mutant <name> <file> <substring> <replacement>: echoes the mutant bin directory's parent.
mutant() {
  local dir="$TMP_ROOT/mutant-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -a "$selflab/bin" "$dir/bin"
  mutate_line "$dir" "$2" "$3" "$4"
  printf '%s\n' "$dir"
}
validate_with() {  # <bin-root> <profile-json>; FM_HOME is the self parent
  printf '%s\n' "$2" > "$selfparent/config/assistances/self.json"
  (cd "$TMP_ROOT" && FM_HOME="$selfparent" "$1/bin/fm-assistance.sh" validate self 2>&1)
}
profile_json() {  # <workdir-json-or-empty>
  jq -n --argjson w "${1:-null}" '{name:"self",harness:"claude",model:"test",effort:"low",charter:"Observe",sources:[],trigger_mode:"self"} + (if $w == null then {} else {workdir:$w} end)'
}
must_refuse_workdir() {  # <bin-root> <workdir> <expected-fragment>
  local out
  if out=$(validate_with "$1" "$(profile_json "$(jq -Rn --arg w "$2" '$w')")"); then fail "workdir accepted: $2"; fi
  [[ "$out" == *"$3"* ]] || fail "workdir refusal for $2 lacked '$3': $out"
}
must_accept_workdir() {  # <bin-root> <workdir>
  validate_with "$1" "$(profile_json "$(jq -Rn --arg w "$2" '$w')")" >/dev/null || fail "mutant did not accept workdir: $2"
}

ln -s "$project" "$TMP_ROOT/project-link"
mkdir -p "$selfparent/sub" "$selfhome/sub" "$TMP_ROOT/fake-checkout/bin" "$TMP_ROOT/secondmate-like/sub"
printf 'x\n' > "$TMP_ROOT/fake-checkout/AGENTS.md"
printf 'x\n' > "$TMP_ROOT/fake-checkout/bin/fm-spawn.sh"
printf 'other\n' > "$TMP_ROOT/secondmate-like/.fm-secondmate-home"
validate_with "$selflab" "$(profile_json "$(jq -Rn --arg w "$project" '$w')")" >/dev/null || fail 'valid workdir was refused'
validate_with "$selflab" "$(profile_json)" >/dev/null || fail 'self mode without a workdir was refused'
must_refuse_workdir "$selflab" project-workdir 'absolute'
must_refuse_workdir "$selflab" "$TMP_ROOT/absent-dir" 'accessible directory'
must_refuse_workdir "$selflab" "$TMP_ROOT/project-link" 'symlink'
must_refuse_workdir "$selflab" "$project/" 'normalized'
must_refuse_workdir "$selflab" "$project/../project-workdir" 'normalized'
must_refuse_workdir "$selflab" "$selfparent/sub" 'firstmate home'
must_refuse_workdir "$selflab" "$selflab/bin" 'firstmate home'
must_refuse_workdir "$selflab" "$selfhome/sub" 'assistance home'
must_refuse_workdir "$selflab" "$TMP_ROOT/secondmate-like/sub" 'secondmate home'
must_refuse_workdir "$selflab" "$TMP_ROOT/fake-checkout" 'firstmate checkout'
if validate_with "$selflab" "$(profile_json 7)" >/dev/null; then fail 'non-string workdir accepted'; fi
if validate_with "$selflab" "$(profile_json | jq '. + {cadence_seconds: 60}')" >/dev/null; then fail 'self mode accepted cadence_seconds'; fi
pass 'validate accepts a real workdir and refuses missing, relative, symlinked and firstmate-home paths'

m=$(mutant relative fm-assistance-guard-lib.sh "echo 'workdir must be an absolute path'" '    *) ;;')
must_accept_workdir "$m" project-workdir
m=$(mutant normalized fm-assistance-guard-lib.sh 'if [[ "$path" == */ ||' 'if false; then')
must_accept_workdir "$m" "$project/"
m=$(mutant symlink fm-assistance-guard-lib.sh "workdir must not be a symlink" ':')
must_accept_workdir "$m" "$TMP_ROOT/project-link"
m=$(mutant missing fm-assistance-guard-lib.sh "workdir is not an accessible directory" '  real=$(CDPATH= cd -P -- "$path" 2>/dev/null && pwd -P) || true')
must_accept_workdir "$m" "$TMP_ROOT/absent-dir"
m=$(mutant contain fm-assistance-guard-lib.sh '"$home" | "$home"/*)' '      "$home" | "$home"/*) ;;')
must_accept_workdir "$m" "$selfparent/sub"
must_accept_workdir "$m" "$selflab/bin"
m=$(mutant marker-assistance fm-assistance-guard-lib.sh 'workdir must not be inside an assistance home' ':')
must_accept_workdir "$m" "$selfhome/sub"
m=$(mutant marker-secondmate fm-assistance-guard-lib.sh 'workdir must not be inside a secondmate home' ':')
must_accept_workdir "$m" "$TMP_ROOT/secondmate-like/sub"
m=$(mutant marker-checkout fm-assistance-guard-lib.sh 'workdir must not be inside a firstmate checkout' ':')
must_accept_workdir "$m" "$TMP_ROOT/fake-checkout"
pass 'each workdir guard is red when removed'

# start passes the profile workdir to the spawn and names absolute paths in the
# charter; without a workdir the spawn and charter are unchanged.
spawnlog="$TMP_ROOT/spawn-args"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$spawnlog" > "$selflab/bin/fm-spawn.sh"
chmod +x "$selflab/bin/fm-spawn.sh"
start_self() {  # <profile-json>; seeded home already registered
  printf '%s\n' "$1" > "$selfparent/config/assistances/self.json"
  rm -f "$selfparent/state/self.meta" "$spawnlog"
  FM_HOME="$selfparent" "$selflab/bin/fm-assistance.sh" start self >/dev/null
}
start_self "$(profile_json "$(jq -Rn --arg w "$project" '$w')")"
grep -qx "self $selfhome --assistance --backend herdr --workdir $project --harness claude --model test --effort low" "$spawnlog" || fail "start did not pass the workdir: $(cat "$spawnlog")"
grep -qx "Your working directory is $project, a project you observe read-only: make no edits, commits, pushes, or state-changing project commands there." "$selfhome/data/charter.md" || fail 'charter lacks the read-only working directory'
grep -qx "Read $selfhome/data/assistance.json for your profile and $selfhome/data/assistance-handoff.md when present." "$selfhome/data/charter.md" || fail 'charter lacks absolute record paths'
grep -q "^Your assistance home is $selfhome; FM_HOME is set to it" "$selfhome/data/charter.md" || fail 'charter does not name the home'
start_self "$(profile_json)"
grep -qx "self $selfhome --assistance --backend herdr --harness claude --model test --effort low" "$spawnlog" || fail "no-workdir start changed the spawn: $(cat "$spawnlog")"
grep -qx 'Read data/assistance.json for your profile and data/assistance-handoff.md when present.' "$selfhome/data/charter.md" || fail 'no-workdir charter paths changed'
! grep -q 'working directory' "$selfhome/data/charter.md" || fail 'no-workdir charter mentions a working directory'
pass 'start passes the workdir to the spawn and leaves the no-workdir launch unchanged'

# self-event: validated record, one doorbell, nothing under the parent home.
cp "$selfparent/config/assistances/self.json" "$selfhome/data/assistance.json"
mkrecord() {  # <message-id> -> echoes the digest-named basename after writing it
  local file="$TMP_ROOT/rec.json" name
  printf '{"schema":"fm-assistance-mentions.v1","messages":[{"id":"%s","arrival":1,"content":"Observe this"}]}\n' "$1" > "$file"
  name=$(jq -c '.messages | map([.id,.arrival])' "$file" | sha256sum | cut -d' ' -f1).json
  mv "$file" "$selfhome/data/pending-mentions/$name"
  printf '%s\n' "$name"
}
snapshot_parent() { (cd "$selfparent" && find . -print0 | sort -z | xargs -0 stat -c '%n %s %Y %F' 2>/dev/null; find . -type f -print0 | sort -z | xargs -0 sha256sum); }
self_event() { FM_HOME="$selfhome" "$1/bin/fm-assistance.sh" self-event "$2" 2>&1; }
rec=$(mkrecord good)
rm -f "$selfhome/state/rings"
before=$(snapshot_parent)
self_event "$selflab" "$rec" >/dev/null || fail 'valid record was not rung'
[ "$(wc -l < "$selfhome/state/rings" | tr -d ' ')" = 1 ] || fail 'valid record did not ring exactly once'
grep -q "^: Assistance source record waiting: read '$selfhome/data/pending-mentions/$rec'" "$selfhome/state/rings" || fail 'doorbell does not name the record'
[ "$(grep -c . "$selfhome/state/rings")" = 1 ] || fail 'doorbell is not one line'
[ "$(snapshot_parent)" = "$before" ] || fail 'self-event touched the parent home'
self_event "$selflab" "$rec" | grep -q '^already rung' || fail 'repeat call did not report the earlier ring'
[ "$(wc -l < "$selfhome/state/rings" | tr -d ' ')" = 1 ] || fail 'repeat call rang again'
pass 'self-event rings the recorded endpoint once for a valid record and leaves the parent home untouched'

# The snapshot is sensitive: the legacy delivery path writes the parent inbox.
printf 'kind=assistance\nharness=claude\nbackend=herdr\nwindow=fixture:pane\nhome=%s\n' "$selfhome" > "$selfparent/state/self.meta"
before=$(snapshot_parent)
FM_HOME="$selfparent" "$selflab/bin/fm-assistance.sh" source-event self "$rec" >/dev/null 2>&1 || true
[ "$(snapshot_parent)" != "$before" ] || fail 'parent snapshot cannot see a parent-home write'
rm -rf "$selfparent/state/self.inbox" "$selfparent/state/self.meta"
rm -f "$selfhome/state/rings"
pass 'the parent snapshot detects a parent-home write'

refuses() {  # <name> <bin-root> <record> <fragment>
  local out
  if out=$(self_event "$2" "$3"); then fail "$1: accepted"; fi
  [[ "$out" == *"$4"* ]] || fail "$1: refusal lacked '$4': $out"
  [ ! -e "$selfhome/state/rings" ] || fail "$1: rang despite refusal"
}
accepts_ring() {  # <name> <bin-root> <record>
  rm -f "$selfhome/state/rings" "$selfhome/state/assistance-rung/$3"
  self_event "$2" "$3" >/dev/null || fail "$1: mutant refused"
  [ -e "$selfhome/state/rings" ] || fail "$1: mutant did not ring"
  rm -f "$selfhome/state/rings" "$selfhome/state/assistance-rung/$3"
}
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
bad_schema=$(mkrecord schema-bad)
jq '.schema = "other"' "$selfhome/data/pending-mentions/$bad_schema" > "$TMP_ROOT/bad.json"; cp "$TMP_ROOT/bad.json" "$selfhome/data/pending-mentions/$bad_schema"
refuses 'schema' "$selflab" "$bad_schema" 'invalid pending mentions'
mismatch=$(mkrecord digest-bad)
jq '.messages[0].id = "changed"' "$selfhome/data/pending-mentions/$mismatch" > "$TMP_ROOT/bad.json"; cp "$TMP_ROOT/bad.json" "$selfhome/data/pending-mentions/$mismatch"
refuses 'digest' "$selflab" "$mismatch" 'content basename mismatch'
refuses 'basename' "$selflab" '../x.json' 'invalid pending record basename'
refuses 'missing record' "$selflab" 'absent.json' 'pending record unavailable'
touch "$selfhome/state/fixture-dead"
refuses 'dead endpoint' "$selflab" "$rec" 'not alive'
rm "$selfhome/state/fixture-dead"
touch "$selfhome/state/fixture-pending"
refuses 'pending composer' "$selflab" "$rec" 'pending text'
rm "$selfhome/state/fixture-pending"
cp "$selfhome/data/assistance.json" "$TMP_ROOT/self-profile.json"
jq '.trigger_mode = "event-driven"' "$TMP_ROOT/self-profile.json" > "$selfhome/data/assistance.json"
refuses 'non-self profile' "$selflab" "$rec" 'trigger_mode self'
cp "$TMP_ROOT/self-profile.json" "$selfhome/data/assistance.json"
pass 'self-event refuses a bad schema, digest, basename, missing record, dead endpoint, pending composer and non-self profile'

m=$(mutant e-schema fm-assistance.sh 'invalid pending mentions' '  :')
accepts_ring schema "$m" "$bad_schema"
m=$(mutant e-digest fm-assistance.sh 'pending record content basename mismatch' '  :')
accepts_ring digest "$m" "$mismatch"
m=$(mutant e-alive fm-assistance.sh 'assistance endpoint is not alive' '      *) ;;')
touch "$selfhome/state/fixture-dead"; accepts_ring alive "$m" "$rec"; rm "$selfhome/state/fixture-dead"
m=$(mutant e-composer fm-assistance.sh 'assistance composer holds pending text' ':')
touch "$selfhome/state/fixture-pending"; accepts_ring composer "$m" "$rec"; rm "$selfhome/state/fixture-pending"
m=$(mutant e-self fm-assistance.sh 'assistance profile does not select trigger_mode self' ':')
jq '.trigger_mode = "event-driven"' "$TMP_ROOT/self-profile.json" > "$selfhome/data/assistance.json"
accepts_ring mode "$m" "$rec"
cp "$TMP_ROOT/self-profile.json" "$selfhome/data/assistance.json"
m=$(mutant e-once fm-assistance.sh 'if [ -f "$marker" ] && [ "$(<"$marker")" = "$endpoint" ]; then' '    if false; then')
rm -f "$selfhome/state/rings"; self_event "$m" "$rec" >/dev/null; self_event "$m" "$rec" >/dev/null
[ "$(wc -l < "$selfhome/state/rings" | tr -d ' ')" = 2 ] || fail 'mutant without the ring marker did not ring twice'
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
pass 'each self-event guard is red when removed'

# Acknowledgement in self mode needs no parent record and deletes only a
# digest-matching record; an event-driven home still needs the parent's inbox.
ack() { FM_HOME="$selfhome" "$1/bin/fm-assistance.sh" acknowledge-source "$2" 2>&1; }
mv "$selfhome/.fm-assistance-parent" "$TMP_ROOT/parent-binding.hold"
self_event "$selflab" "$rec" >/dev/null || fail 'record was not rung before acknowledgement'
if ack "$selflab" "$mismatch" >/dev/null; then fail 'self ack accepted a mutated record'; fi
[ -f "$selfhome/data/pending-mentions/$mismatch" ] || fail 'refused self ack deleted evidence'
ack "$selflab" "$rec" >/dev/null || fail 'self ack refused a digest-matching record without a parent'
[ ! -e "$selfhome/data/pending-mentions/$rec" ] || fail 'self ack kept the record'
[ ! -e "$selfhome/state/assistance-rung/$rec" ] || fail 'self ack kept the ring marker'
if ack "$selflab" "$rec" >/dev/null; then fail 'self ack succeeded for a missing record'; fi
mv "$TMP_ROOT/parent-binding.hold" "$selfhome/.fm-assistance-parent"
pass 'self-mode acknowledgement deletes only a digest-matching record and needs no parent record'

ev=$(mkrecord event-driven)
jq '.trigger_mode = "event-driven"' "$TMP_ROOT/self-profile.json" > "$selfhome/data/assistance.json"
if ack "$selflab" "$ev" > "$TMP_ROOT/ev-ack.out"; then fail 'event-driven ack skipped the parent inbox'; fi
grep -q 'source inbox acknowledgement required' "$TMP_ROOT/ev-ack.out" || fail 'event-driven ack lacked the parent requirement'
m=$(mutant a-self fm-assistance.sh 'self_mode() {' 'self_mode() { return 0; }')
ack "$m" "$ev" >/dev/null || fail 'mutant self-mode switch did not skip the parent inbox'
cp "$TMP_ROOT/self-profile.json" "$selfhome/data/assistance.json"
pass 'event-driven profiles still require the parent acknowledgement and the self switch is red when forced'

# fm-spawn re-checks the workdir itself, since a profile can be edited after
# validate and the spawn is what sets the pane directory and the Claude trust.
cp "$ROOT/bin/fm-spawn.sh" "$selflab/bin/fm-spawn.sh"
spawn_workdir() {  # <bin-root> <args...>
  local root=$1
  shift
  FM_HOME="$selfparent" FM_SPAWN_NO_GUARD=1 "$root/bin/fm-spawn.sh" self "$selfhome" --assistance --backend herdr --harness claude "$@" 2>&1
}
out=$(spawn_workdir "$selflab" --workdir relative/dir) && fail 'spawn accepted a relative workdir'
[[ "$out" == *'invalid assistance workdir: workdir must be an absolute path'* ]] || fail "spawn workdir refusal lacked its reason: $out"
out=$(spawn_workdir "$selflab" --workdir "$TMP_ROOT/project-link") && fail 'spawn accepted a symlink workdir'
[[ "$out" == *'workdir must not be a symlink'* ]] || fail "spawn symlink refusal lacked its reason: $out"
out=$(spawn_workdir "$selflab" --workdir) && fail 'spawn accepted an empty --workdir'
[[ "$out" == *'--workdir requires a value'* ]] || fail "spawn missing-value refusal: $out"
out=$(FM_HOME="$selfparent" FM_SPAWN_NO_GUARD=1 "$selflab/bin/fm-spawn.sh" worker "$project" --workdir "$project" --mode direct-PR --yolo off 2>&1) && fail 'spawn accepted --workdir outside assistance'
[[ "$out" == *'--workdir applies only to --assistance spawns'* ]] || fail "spawn non-assistance refusal: $out"
m=$(mutant s-validate fm-spawn.sh 'WORKDIR_REASON=$(fm_assistance_workdir_error "$WORKDIR_ARG") || {' '  WORKDIR_REASON=$(true) || {')
out=$(spawn_workdir "$m" --workdir relative/dir) || true
[[ "$out" != *'invalid assistance workdir'* ]] || fail 'spawn workdir validation is not red when removed'
m=$(mutant s-assistance-only fm-spawn.sh '  [ "$ASSISTANCE" -eq 1 ] || {' '  true || {')
out=$(FM_HOME="$selfparent" FM_SPAWN_NO_GUARD=1 "$m/bin/fm-spawn.sh" worker "$project" --workdir "$project" --mode direct-PR --yolo off 2>&1) || true
[[ "$out" != *'applies only to --assistance'* ]] || fail 'assistance-only guard is not red when removed'
pass 'fm-spawn refuses a bad or misplaced workdir and each spawn guard is red when removed'

# A doorbell counts as delivered only on the exact verdict "empty"; any other
# verdict leaves the record retryable (the composer-pending check holds the retry
# until the typed text clears).
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
rec=$(mkrecord good)
for verdict in pending unknown send-failed; do
  printf '%s\n' "$verdict" > "$selfhome/state/fixture-verdict"
  if out=$(self_event "$selflab" "$rec"); then fail "verdict $verdict was treated as delivered"; fi
  [[ "$out" == *'not confirmed'* ]] || fail "verdict $verdict refusal lacked its reason: $out"
  [ ! -e "$selfhome/state/assistance-rung/$rec" ] || fail "verdict $verdict wrote the ring marker"
done
rm "$selfhome/state/fixture-verdict"
self_event "$selflab" "$rec" >/dev/null || fail 'a confirmed doorbell was refused after unconfirmed attempts'
[ -f "$selfhome/state/assistance-rung/$rec" ] || fail 'a confirmed doorbell left no marker'
m=$(mutant e-verdict fm-assistance.sh '[ "$verdict" = empty ] || die' '    :')
rm -rf "$selfhome/state/assistance-rung"
printf 'pending\n' > "$selfhome/state/fixture-verdict"
self_event "$m" "$rec" >/dev/null || fail 'verdict mutant refused'
[ -f "$selfhome/state/assistance-rung/$rec" ] || fail 'verdict guard is not red when removed'
rm -rf "$selfhome/state/fixture-verdict" "$selfhome/state/assistance-rung" "$selfhome/state/rings"
pass 'self-event writes its ring marker only on the exact empty verdict'

# The workdir launch loads Claude's project setting source, so a workdir whose
# project settings define a command-running key would run that command inside
# the read-only role. validate and the spawn both refuse it through the shared
# guard and name the file and key.
settings_workdir() {  # <name> <settings-file> <json> -> echoes the workdir
  local dir="$TMP_ROOT/wd-$1"
  mkdir -p "$dir/.claude"
  printf '%s\n' "$3" > "$dir/.claude/$2"
  printf '%s\n' "$dir"
}
for key in hooks statusLine subagentStatusLine apiKeyHelper awsAuthRefresh awsCredentialExport gcpAuthRefresh otelHeadersHelper fileSuggestion enabledPlugins extraKnownMarketplaces enableAllProjectMcpServers enabledMcpjsonServers; do
  case "$key" in
    hooks | enabledPlugins | extraKnownMarketplaces) value='{"x":["y"]}' ;;
    enabledMcpjsonServers) value='["srv"]' ;;
    enableAllProjectMcpServers) value='true' ;;
    *) value='{"type":"command","command":"true"}' ;;
  esac
  dir=$(settings_workdir "key-$key" settings.json "$(jq -n --arg k "$key" --argjson v "$value" '{($k): $v}')")
  must_refuse_workdir "$selflab" "$dir" "defines command-running key '$key'"
done
dir=$(settings_workdir local settings.local.json '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}')
must_refuse_workdir "$selflab" "$dir" ".claude/settings.local.json defines command-running key 'hooks'"
dir=$(settings_workdir invalid settings.json '{not json')
must_refuse_workdir "$selflab" "$dir" 'cannot be read as a JSON object'
dir=$(settings_workdir quiet settings.json '{"permissions":{"allow":["Read"]},"env":{"A":"b"},"hooks":{},"statusLine":null}')
must_accept_workdir "$selflab" "$dir"
out=$(spawn_workdir "$selflab" --workdir "$TMP_ROOT/wd-key-hooks") && fail 'spawn accepted a workdir with project hooks'
[[ "$out" == *"defines command-running key 'hooks'"* ]] || fail "spawn hooks refusal lacked its reason: $out"
m=$(mutant settings fm-assistance-guard-lib.sh 'defines command-running key' ':')
must_accept_workdir "$m" "$TMP_ROOT/wd-key-hooks"
pass 'a workdir whose project settings run a command is refused by validate and spawn, naming file and key'

# Two overlapping self-event calls for one record ring once: the marker check,
# the send and the marker write run under one per-record lock in the home.
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
rec=$(mkrecord good)
touch "$selfhome/state/fixture-slow"
self_event "$selflab" "$rec" > "$TMP_ROOT/overlap-a.out" 2>&1 &
pid_a=$!
self_event "$selflab" "$rec" > "$TMP_ROOT/overlap-b.out" 2>&1 &
pid_b=$!
wait "$pid_a" "$pid_b"
[ "$(wc -l < "$selfhome/state/rings" | tr -d ' ')" = 1 ] || fail "overlapping self-event calls rang $(wc -l < "$selfhome/state/rings") times"
cat "$TMP_ROOT/overlap-a.out" "$TMP_ROOT/overlap-b.out" | grep -q '^already rung' || fail 'the second overlapping call did not see the first ring'
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
m=$(mutant e-lock fm-assistance.sh 'fm_lock_acquire_wait "$RECORD_LOCK"' '  :')
self_event "$m" "$rec" > "$TMP_ROOT/overlap-a.out" 2>&1 &
pid_a=$!
self_event "$m" "$rec" > "$TMP_ROOT/overlap-b.out" 2>&1 &
pid_b=$!
wait "$pid_a" "$pid_b"
[ "$(wc -l < "$selfhome/state/rings" | tr -d ' ')" = 2 ] || fail 'the ring lock is not red when removed'
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings" "$selfhome/state/fixture-slow"
pass 'overlapping self-event calls for one record ring once, and the lock is red when removed'

# The cwd is the workdir, so every command a notification names is an absolute
# path into the assistance home.
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
rec=$(mkrecord good)
self_event "$selflab" "$rec" >/dev/null
grep -qF "propose concrete work through $selfhome/bin/fm-assistance.sh propose" "$selfhome/state/rings" || fail 'doorbell does not name the absolute propose command'
grep -qF "then run $selfhome/bin/fm-assistance.sh acknowledge-source $rec." "$selfhome/state/rings" || fail 'doorbell does not name the absolute acknowledge command'
printf '{"cadence_seconds":1}\n' > "$selfhome/data/assistance.json"
printf 'cad\n' > "$selfhome/state/assistance-session"
set +e
printf '{"session_id":"cad"}\n' | FM_HOME="$selfhome" "$ROOT/bin/fm-assistance-hook.sh" cadence > "$TMP_ROOT/cad-hook.out" 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail "cadence hook did not request a turn: rc=$rc"
grep -qF "$selfhome/bin/fm-wake-drain.sh" "$TMP_ROOT/cad-hook.out" || fail 'cadence message does not name the absolute wake-drain command'
grep -qF "$selfhome/bin/fm-procevent.sh handled" "$TMP_ROOT/cad-hook.out" || fail 'cadence message does not name the absolute procevent command'
FM_HOME="$selfhome" "$ROOT/bin/fm-procevent.sh" retire assistance-cadence >/dev/null 2>&1 || true
cp "$TMP_ROOT/self-profile.json" "$selfhome/data/assistance.json"
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
pass 'doorbell and cadence messages name absolute commands in the assistance home'

# The record check runs inside the per-record lock, and self-mode acknowledgement
# takes the same lock around its check and delete, so a ring and an
# acknowledgement of one record never interleave.
hold_lock() {  # <lockdir> <seconds>: hold the lock in a background shell until released
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; : > "$2.held"; sleep "$3"; fm_lock_release "$2"' _ "$selflab" "$1" "$2" &
  HOLD_PID=$!
  for _ in $(seq 1 50); do [ -e "$1.held" ] && break; sleep 0.1; done
  [ -e "$1.held" ] || fail 'test lock holder did not start'
}
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings" "$selfhome"/state/.assistance-ring-*
rec=$(mkrecord good)
lock="$selfhome/state/.assistance-ring-$rec.lock"
# A ring that waits for the lock re-checks the record once it holds it.
hold_lock "$lock" 2
self_event "$selflab" "$rec" > "$TMP_ROOT/inlock-ring.out" 2>&1 &
ring_pid=$!
sleep 0.5
rm -f "$selfhome/data/pending-mentions/$rec"
wait "$HOLD_PID"
rm -f "$lock.held"
if wait "$ring_pid"; then fail 'a ring that waited for the lock accepted a record deleted meanwhile'; fi
[ ! -e "$selfhome/state/rings" ] || fail 'a ring typed a doorbell for a record deleted while it waited'
m=$(mutant l-check fm-assistance.sh '    pending_record_check "$FM_HOME/data/pending-mentions/$2" "$2"' '    :')
mutate_line "$m" fm-assistance.sh '    record_lock "$2"' '    pending_record_check "$FM_HOME/data/pending-mentions/$2" "$2"; record_lock "$2"'
rec=$(mkrecord good)
hold_lock "$lock" 2
self_event "$m" "$rec" > "$TMP_ROOT/inlock-ring.out" 2>&1 &
ring_pid=$!
sleep 0.5
rm -f "$selfhome/data/pending-mentions/$rec"
wait "$HOLD_PID"
wait "$ring_pid" || true
rm -f "$lock.held"
[ -e "$selfhome/state/rings" ] || fail 'the in-lock record check is not red when it runs before the lock'
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
# Acknowledgement waits for a ring that holds the lock, then deletes record and marker together.
rec=$(mkrecord good)
hold_lock "$lock" 2
ack "$selflab" "$rec" > "$TMP_ROOT/inlock-ack.out" 2>&1 &
ack_pid=$!
sleep 0.7
[ -f "$selfhome/data/pending-mentions/$rec" ] || fail 'self-mode acknowledgement deleted a record while its ring lock was held'
wait "$ack_pid" || fail "self-mode acknowledgement failed after the lock cleared: $(cat "$TMP_ROOT/inlock-ack.out")"
wait "$HOLD_PID"
rm -f "$lock.held"
[ ! -e "$selfhome/data/pending-mentions/$rec" ] || fail 'self-mode acknowledgement kept the record after the lock cleared'
rec=$(mkrecord good)
m=$(mutant l-ack fm-assistance.sh '! self_mode || record_lock "$2"' '    :')
hold_lock "$lock" 2
ack "$m" "$rec" > "$TMP_ROOT/inlock-ack.out" 2>&1 &
ack_pid=$!
sleep 0.7
[ ! -f "$selfhome/data/pending-mentions/$rec" ] || fail 'the acknowledgement lock is not red when removed'
wait "$HOLD_PID"
wait "$ack_pid" || true
rm -f "$lock.held"
rm -rf "$selfhome/state/assistance-rung" "$selfhome/state/rings"
pass 'self-event checks the record inside its lock and self-mode acknowledgement takes the same lock'
