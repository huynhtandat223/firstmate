#!/usr/bin/env bash
# Offline record reads must preserve the local handoff path.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-offline-rotation)
mkdir -p "$TMP_ROOT/code/bin" "$TMP_ROOT/home"/{data,state} "$TMP_ROOT/parent/state"
cp -a "$ROOT/bin/." "$TMP_ROOT/code/bin/"
printf '#!/usr/bin/env bash\nexit 3\n' > "$TMP_ROOT/code/bin/fm-task.sh"
chmod +x "$TMP_ROOT/code/bin/fm-task.sh"
home="$TMP_ROOT/home"
printf 'sample\n' > "$home/.fm-assistance-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/parent" > "$home/.fm-assistance-parent"
printf '{"name":"sample"}\n' > "$home/data/assistance.json"
printf '{"session":"proof","at":1}\n' > "$home/state/assistance-rotation.json"
printf 'proof\n' > "$home/state/assistance-session"
printf 'owned:unavailable\n' > "$home/state/assistance-endpoint"
printf 'persisted notes\n' > "$home/data/assistance-stow.md"
printf '## Suggested skills\nNone\n## Next action\nContinue local handoff\n' > "$home/data/assistance-handoff.md"
if FM_HOME="$home" "$TMP_ROOT/code/bin/fm-assistance-rotate.sh" > "$TMP_ROOT/out" 2>&1; then fail 'invalid endpoint unexpectedly accepted'; fi
grep -q 'task record unavailable; continue from persisted handoff' "$TMP_ROOT/out" || fail 'offline fallback absent'
grep -q 'endpoint no longer matches' "$TMP_ROOT/out" || fail 'offline read stopped before local endpoint safety check'
pass 'offline task record preserves handoff and reaches local endpoint validation'
S="printf '[]\\n' > \"\$resume_tmp\"" R='exit 1' perl -0pi -e 's/\Q$ENV{S}\E/$ENV{R}/' "$TMP_ROOT/code/bin/fm-assistance-rotate.sh"
FM_HOME="$home" "$TMP_ROOT/code/bin/fm-assistance-rotate.sh" > "$TMP_ROOT/mutant.out" 2>&1 || true
if grep -q 'endpoint no longer matches' "$TMP_ROOT/mutant.out"; then fail 'offline refusal mutation survived'; fi
pass 'offline rotation case goes red when fallback is removed'
