#!/usr/bin/env bash
# Resolve thresholds through spawn and preserve them across relaunch.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
tmp=$(fm_test_tmproot fm-handoff-threshold-spawn)
trap 'rm -rf "$tmp"' EXIT
fakebin=$(fm_test_make_spawn_fakebin "$tmp/fake" pi)
home="$tmp/home"
fm_test_spawn_home "$home" pi
fm_git_worktree "$tmp/project" "$tmp/wt" threshold-test
cat > "$home/config/handoff-thresholds" <<'CONFIG'
openai-codex/gpt-6-astra off
cx/gpt-6-astra 25
*/gpt-6.1-sol off
CONFIG
n=0
for pair in 'openai-codex/gpt-6-astra off' 'cx/gpt-6-astra 25' 'cx/gpt-6.1-sol off' 'other/model 40'; do
  read -r model expected <<< "$pair"
  n=$((n + 1))
  id="threshold-$n"
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$tmp/wt" "$fakebin" "$id" "$tmp/project" --model "$model" --mode direct-PR --yolo off) || fail "$out"
  grep -qx "handoff_pct=$expected" "$home/state/$id.meta" || fail "$model did not resolve $expected"
done
for id in threshold-1 threshold-3; do
  if grep -Eq 'contextTurnEnd|fm-context-handoff' "$home/state/$id.pi-ext.ts"; then fail 'off Pi wired handoff'; fi
  grep -q 'execFile("touch"' "$home/state/$id.pi-ext.ts" || fail 'off Pi lost turn-end'
done
grep -q 'await contextTurnEnd' "$home/state/threshold-2.pi-ext.ts" || fail 'numbered Pi lost handoff'
for pair in 'claude-off openai-codex/gpt-6-astra' 'claude-number cx/gpt-6-astra'; do
  read -r id model <<< "$pair"
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$tmp/wt" "$fakebin" "$id" "$tmp/project" --harness claude --model "$model" --mode direct-PR --yolo off) || fail "$out"
  python3 - "$tmp/wt/.claude/settings.local.json" "$id" <<'PY'
import json,sys
command=json.load(open(sys.argv[1]))['hooks']['Stop'][0]['hooks'][0]['command']
assert 'touch ' in command
assert ('fm-context-handoff.mjs' in command) == (sys.argv[2] == 'claude-number')
PY
done
echo 'PASS: model resolution and off/numbered Claude and Pi wiring'
