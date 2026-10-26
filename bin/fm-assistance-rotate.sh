#!/usr/bin/env bash
# Self-owned Claude rotation on the assistance's recorded Herdr endpoint.
# Usage: fm-assistance-rotate.sh
# Requires a 40% request, current-session stow and a fresh handoff, then detaches
# to wait for idle and /clear. The SessionStart hook loads the handoff.
# No parent control or steering command is used. A changed session confirms clear.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?rotation requires FM_HOME}"
STATE="$FM_HOME/state"
[ -f "$FM_HOME/.fm-assistance-home" ] || { echo 'error: rotation requires an assistance home' >&2; exit 1; }
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
request="$STATE/assistance-rotation.json"
[ -f "$request" ] || { echo 'error: no context rotation request' >&2; exit 1; }
session=$(jq -er .session "$request")
at=$(jq -er .at "$request")
[ "$(<"$STATE/assistance-session")" = "$session" ] || { echo 'error: stale rotation request' >&2; exit 1; }
for file in assistance-stow.md assistance-handoff.md; do
  path="$FM_HOME/data/$file"
  [ -s "$path" ] && [ ! -L "$path" ] || { echo "error: missing ordinary $file" >&2; exit 1; }
  modified=$(date -r "$path" +%s 2>/dev/null || stat -f %m "$path")
  [ "$modified" -ge "$at" ] || { echo "error: stale $file; stow this session before rotation" >&2; exit 1; }
done
grep -qi '^## Suggested skills' "$FM_HOME/data/assistance-handoff.md" || { echo 'error: handoff lacks Suggested skills' >&2; exit 1; }
grep -qi '^## Next action' "$FM_HOME/data/assistance-handoff.md" || { echo 'error: handoff lacks Next action' >&2; exit 1; }
# Rebuild task context from the record before any rotation action.
resume_file="$FM_HOME/data/assistance-task-resume.md"
resume_tmp=$(mktemp "$FM_HOME/data/.task-resume.XXXXXX")
if ! "$SCRIPT_DIR/fm-task.sh" list --json > "$resume_tmp"; then rm -f "$resume_tmp"; exit 1; fi
name=$(<"$FM_HOME/.fm-assistance-home")
tasks=$(jq -r --arg name "$name" '.[] | select(.assignee == $name and .state != "done" and .state != "archived") | .taskId' "$resume_tmp")
: > "$resume_tmp"
while IFS= read -r task; do
  [ -n "$task" ] || continue
  if ! "$SCRIPT_DIR/fm-task.sh" resume "$task" >> "$resume_tmp"; then rm -f "$resume_tmp"; exit 1; fi
done <<< "$tasks"
mv "$resume_tmp" "$resume_file"
endpoint=$(<"$STATE/assistance-endpoint")
name=$(<"$FM_HOME/.fm-assistance-home")
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || exit 1
if ! fm_secondmate_parent_record_parse "$FM_HOME/.fm-assistance-parent" || [ "$FM_SECONDMATE_PARENT_ROUTE" != local ]; then
  echo 'error: assistance parent binding is invalid or unsupported' >&2
  exit 1
fi
parent=$FM_SECONDMATE_PARENT_HOME
meta="$parent/state/$name.meta"
if [ "$(fm_meta_get "$meta" kind)" != assistance ] ||
  [ "$(fm_meta_get "$meta" home)" != "$FM_HOME" ] ||
  [ "$(fm_backend_target_of_meta "$meta")" != "$endpoint" ]; then
  echo 'error: assistance rotation endpoint no longer matches its parent record' >&2
  exit 1
fi
if [ "${FM_ASSISTANCE_ROTATE_CHILD:-}" != 1 ]; then
  FM_ASSISTANCE_ROTATE_CHILD=1 nohup "$0" > "$STATE/assistance-rotation.log" 2>&1 < /dev/null &
  echo 'rotation: scheduled after this turn; stow and handoff retained'
  exit 0
fi
lock="$STATE/.assistance-rotation.lock"
fm_lock_try_acquire "$lock" || exit 0
trap 'fm_lock_release "$lock"' EXIT
for ((attempt=0; attempt<300; attempt++)); do
  [ "$(<"$STATE/assistance-session")" = "$session" ] || exit 0
  if [ "$(fm_backend_agent_state herdr "$endpoint")" != alive ]; then
    echo 'error: assistance process cannot be confirmed'; exit 1
  fi
  if [ "$(fm_backend_busy_state herdr "$endpoint" 2>/dev/null)" = idle ] &&
    [ "$(fm_backend_composer_state herdr "$endpoint" 2>/dev/null)" = empty ]; then
    verdict=$(fm_backend_send_text_submit herdr "$endpoint" /clear 3 0.2 1.2)
    [ "$verdict" = empty ] || { echo "error: clear not confirmed: $verdict"; exit 1; }
    break
  fi
  sleep 1
done
for ((attempt=0; attempt<60; attempt++)); do
  if [ "$(<"$STATE/assistance-session")" != "$session" ]; then
    rm -f "$request"
    fm_backend_send_text_submit herdr "$endpoint" "First run bin/fm-task.sh resume for each task in $FM_HOME/data/assistance-task-resume.md. Then read $FM_HOME/data/charter.md and $FM_HOME/data/assistance-handoff.md and continue from Next action." 3 0.2 1.2
    echo 'rotation: fresh session continuing from persisted handoff'
    exit 0
  fi
  sleep 1
done
echo 'error: fresh assistance session was not confirmed' >&2
exit 1
