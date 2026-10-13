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
"$ROOT/bin/fm-assistance.sh" recover
pass 'disabled assistance is not restarted'
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
# The registry is deliberately populated, but secondmate routing cannot use it.
if "$ROOT/bin/fm-backlog-handoff.sh" sample "proposal-$id" > "$TMP_ROOT/handoff.out" 2>&1; then fail 'secondmate handoff adopted an assistance'; fi
"$ROOT/bin/fm-tasks-axi.sh" show "proposal-$id" >/dev/null || fail 'refused handoff moved the proposal'
pass 'secondmate handoff ignores the assistance registry'
