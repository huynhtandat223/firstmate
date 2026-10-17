#!/usr/bin/env bash
# Worker context notifications through the executable and status classifier.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
tmp=$(fm_test_tmproot fm-context-handoff)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/handoff-thresholds" <<'CONFIG'
# Auto-compacting and large-window models
openai-codex/gpt-6-astra off
cx/gpt-6-astra 25
*/gpt-6.1-sol off
* 40
CONFIG
for pair in 'openai-codex/gpt-6-astra off' 'cx/gpt-6-astra 25' 'cx/gpt-6.1-sol off' 'other/model 40'; do
  read -r model expected <<< "$pair"
  actual=$("$ROOT/bin/fm-handoff-threshold.sh" "$tmp/handoff-thresholds" "$model")
  [ "$actual" = "$expected" ] || fail "$model: expected $expected, got $actual"
done
[ "$("$ROOT/bin/fm-handoff-threshold.sh" "$tmp/absent" any)" = 40 ] || fail 'absent default'
[ "$("$ROOT/bin/fm-handoff-threshold.sh" "$tmp/handoff-thresholds" any off)" = off ] || fail 'relaunch preserves off'
[ "$("$ROOT/bin/fm-handoff-threshold.sh" "$tmp/handoff-thresholds" any 25)" = 25 ] || fail 'relaunch preserves numbered threshold'
node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/quarter.status" quarter 25 24999 100000
[ ! -e "$tmp/quarter.status" ] || fail '25 threshold fired early'
node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/quarter.status" quarter 25 25000 100000
grep -q 'context 25% (25000/100000)' "$tmp/quarter.status" || fail '25 threshold'
status="$tmp/task.status"
node "$ROOT/bin/fm-context-handoff.mjs" "$status" a 40 39999 100000
[ ! -e "$status" ] || fail 'below threshold emitted'
for generation in a b c d; do
  node "$ROOT/bin/fm-context-handoff.mjs" "$status" "$generation" 40 40000 100000
  node "$ROOT/bin/fm-context-handoff.mjs" "$status" "$generation" 40 50000 100000
done
[ "$(grep -c '^handoff-needed ' "$status")" = 3 ] || fail 'handoff count'
[ "$(grep -c '^blocked .*handoff-limit' "$status")" = 1 ] || fail 'fourth trigger'
[ "$(wc -l < "$status" | tr -d ' ')" = 4 ] || fail 'per-session duplicate'
printf old > "$tmp/concurrent.status.handoff-session"
for run in 1 2 3 4 5 6 7 8; do
  node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/concurrent.status" new 40 50000 100000 &
done
wait
[ "$(grep -c '^handoff-needed ' "$tmp/concurrent.status")" = 1 ] || fail 'concurrent generation claim duplicated'
status_is_captain_relevant "$(head -1 "$status")" || fail 'handoff notification not actionable'
status_is_captain_relevant "$(tail -1 "$status")" || fail 'limit not actionable'
printf '%s\n' '{"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10000,"cache_read_input_tokens":60000,"cache_creation_input_tokens":10000}}}' > "$tmp/transcript"
printf '{"transcript_path":"%s"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/claude.status" e 40 claude default
grep -q 'context 40% (80000/200000)' "$tmp/claude.status" || fail 'Claude cache measurement'
printf '%s\n' '{"message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"toolu_test","name":"Read","input":{}}],"usage":{"input_tokens":10000,"cache_read_input_tokens":60000,"cache_creation_input_tokens":10000}}}' > "$tmp/transcript"
printf '{"transcript_path":"%s","last_assistant_message":"not flushed yet"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/tool-use.status" g 40 claude default
grep -q 'handoff-needed .*context 40% (80000/200000)' "$tmp/tool-use.status" || fail 'Claude newest tool-use usage fallback'
for invocation in 1 2; do
  printf '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{},"tool_response":"ok","transcript_path":"%s"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/post-tool.status" post-tool 40 claude default
done
[ "$(grep -c '^handoff-needed ' "$tmp/post-tool.status")" = 1 ] || fail 'Claude PostToolUse repeated in same generation'
[ "$(wc -l < "$tmp/post-tool.status" | tr -d ' ')" = 1 ] || fail 'Claude PostToolUse duplicate output'
printf '{"hook_event_name":"PostToolUse","transcript_path":"%s"}' "$tmp/missing-transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/post-tool.status" post-tool 40 claude default
[ "$(wc -l < "$tmp/post-tool.status" | tr -d ' ')" = 1 ] || fail 'marked generation read transcript or emitted output'
printf '%s\n' '{"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10000}}}' > "$tmp/transcript"
(sleep 0.5; printf '%s\n' '{"message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"toolu_late","name":"Read","input":{}}],"usage":{"input_tokens":80000}}}' >> "$tmp/transcript") &
printf '{"transcript_path":"%s","last_assistant_message":"not flushed yet"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/late-tool-use.status" h 40 claude default
wait
printf '%s\n' '{"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10000}}}' > "$tmp/partial-transcript"
printf '%s' '{"message":{"model":"claude-haiku-4-5","usage":' >> "$tmp/partial-transcript"
(sleep 0.5; printf '%s\n' '{"input_tokens":80000}}}' >> "$tmp/partial-transcript") &
printf '{"hook_event_name":"PostToolUse","transcript_path":"%s"}' "$tmp/partial-transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/partial.status" partial 40 claude default
wait
grep -q 'context 40% (80000/200000)' "$tmp/partial.status" || fail 'partial PostToolUse transcript did not retry'
grep -q 'handoff-needed .*context 40% (80000/200000)' "$tmp/late-tool-use.status" || fail 'Claude retries use newly flushed usage entry'
printf '%s\n' '{"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10000,"cache_read_input_tokens":60000,"cache_creation_input_tokens":10000}}}' > "$tmp/transcript"
printf '{"transcript_path":"%s"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/one-million.status" f 8 claude 'haiku[1m]'
grep -q 'context 8% (80000/1000000)' "$tmp/one-million.status" || fail '[1m] window'
for model in claude-opus-5-5-200k claude-sonnet-5-5-200k; do
  printf '{"message":{"model":"%s","usage":{"input_tokens":80000}}}\n' "$model" > "$tmp/transcript"
  printf '{"transcript_path":"%s"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/$model.status" "$model" 40 claude default
  grep -q 'context 40% (80000/200000)' "$tmp/$model.status" || fail 'explicit 200k window'
done
# The preload counts actual transcript read bytes, not implementation source.
cat > "$tmp/read-budget.cjs" <<'JS'
const fs = require('node:fs');
const original = fs.readSync;
let bytes = 0;
fs.readSync = function(...args) {
  const result = original.apply(this, args);
  bytes += result;
  if (bytes > 131072) throw Error('transcript read exceeded bounded tail budget');
  return result;
};
JS
python3 - "$tmp/large-transcript" <<'PYTHON'
import sys
with open(sys.argv[1], 'w') as f:
    for _ in range(100000):
        f.write('{"padding":"' + 'x' * 200 + '"}\n')
    f.write('{"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":80000}}}\n')
PYTHON
printf '{"transcript_path":"%s"}' "$tmp/large-transcript" | node --require "$tmp/read-budget.cjs" "$ROOT/bin/fm-context-handoff.mjs" "$tmp/large.status" large 40 claude default
grep -q '^handoff-needed ' "$tmp/large.status" || fail 'large transcript tail measurement'
node --input-type=module - "$ROOT" "$tmp" <<'JS'
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
const [root, tmp] = process.argv.slice(2);
const { contextTurnEnd } = await import(pathToFileURL(`${root}/bin/fm-context-turn-end.mjs`));
await contextTurnEnd(`${tmp}/missing-helper.mjs`, [], `${tmp}/turn-ended`);
if (!fs.existsSync(`${tmp}/turn-ended`)) throw Error('failed helper lost turn-end notification');
JS
echo 'PASS: threshold, once per session, fourth-trigger limit, actionable status, Claude usage/window, failing helper preserves turn end'
