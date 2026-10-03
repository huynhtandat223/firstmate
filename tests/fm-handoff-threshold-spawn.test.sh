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
echo 'PASS: spawn resolves all four model cases'
