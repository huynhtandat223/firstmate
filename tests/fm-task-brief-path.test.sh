#!/usr/bin/env bash
# Render terminal instructions outside the Firstmate code directory.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-brief-path)
mkdir -p "$TMP_ROOT/home/data"
FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-brief.sh" path-proof other-project --mode direct-PR >/dev/null
brief="$TMP_ROOT/home/data/path-proof/brief.md"
grep -F "Terminal call: end each worker turn with exactly one \`$ROOT/bin/fm-task.sh" "$brief" >/dev/null || fail 'terminal writer path is not absolute'
grep -F "Read \`$ROOT/bin/fm-task.sh resume path-proof\` first" "$brief" >/dev/null || fail 'resume path is not absolute'
pass 'ship terminal and resume paths resolve outside the worker project'
mkdir -p "$TMP_ROOT/mutant/bin" "$TMP_ROOT/mutant-home/data"
cp -a "$ROOT/bin/." "$TMP_ROOT/mutant/bin/"
# Remove absolute resolution in a copy, then observe the rendered public output.
S='$FM_ROOT/bin/fm-task.sh' R='bin/fm-task.sh' perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/g' "$TMP_ROOT/mutant/bin/fm-brief.sh"
FM_HOME="$TMP_ROOT/mutant-home" "$TMP_ROOT/mutant/bin/fm-brief.sh" path-proof other-project --mode direct-PR >/dev/null
if grep -F "Terminal call: end each worker turn with exactly one \`$TMP_ROOT/mutant/bin/fm-task.sh" "$TMP_ROOT/mutant-home/data/path-proof/brief.md" >/dev/null; then
  fail 'relative-path mutation survived the absolute-path assertion'
fi
pass 'absolute-path regression goes red when absolute resolution is removed'
