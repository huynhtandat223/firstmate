#!/usr/bin/env bash
# Worker context notifications through the executable and status classifier.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
tmp=$(fm_test_tmproot fm-context-handoff)
trap 'rm -rf "$tmp"' EXIT
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
status_is_captain_relevant "$(head -1 "$status")" || fail 'handoff notification not actionable'
status_is_captain_relevant "$(tail -1 "$status")" || fail 'limit not actionable'
printf '%s\n' '{"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10000,"cache_read_input_tokens":60000,"cache_creation_input_tokens":10000}}}' > "$tmp/transcript"
printf '{"transcript_path":"%s"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/claude.status" e 40 claude default
grep -q 'context 40% (80000/200000)' "$tmp/claude.status" || fail 'Claude cache measurement'
printf '{"transcript_path":"%s"}' "$tmp/transcript" | node "$ROOT/bin/fm-context-handoff.mjs" "$tmp/one-million.status" f 8 claude 'haiku[1m]'
grep -q 'context 8% (80000/1000000)' "$tmp/one-million.status" || fail '[1m] window'
node --input-type=module - "$ROOT" "$tmp" <<'JS'
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
const [root, tmp] = process.argv.slice(2);
const { contextTurnEnd } = await import(pathToFileURL(`${root}/bin/fm-context-turn-end.mjs`));
await contextTurnEnd(`${tmp}/missing-helper.mjs`, [], `${tmp}/turn-ended`);
if (!fs.existsSync(`${tmp}/turn-ended`)) throw Error('failed helper lost turn-end notification');
JS
echo 'PASS: threshold, once per session, fourth-trigger limit, actionable status, Claude usage/window, failing helper preserves turn end'
