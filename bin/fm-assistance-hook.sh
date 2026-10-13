#!/usr/bin/env bash
# Claude assistance hooks. Usage: fm-assistance-hook.sh start|usage|stop|cadence
# Owns current session identity, measured context and the 40-percent request.
# Claude's statusLine supplies the actual context-window capacity; no model table.
# stop requests stow and handoff; rotation occurs only through the self command.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:?assistance hooks require FM_HOME}"
STATE="$FM_HOME/state"
[ -f "$FM_HOME/.fm-assistance-home" ] || exit 1
if [ "${1:-}" = settings ]; then
  hook="'${SCRIPT_DIR//\'/\'\\\'\'}/fm-assistance-hook.sh'"
  jq -n --arg hook "$hook" '{
    feedbackDrafts:"off", attribution:{commit:"",pr:"",sessionUrl:false},
    permissions:{deny:["Agent","Task"]},
    statusLine:{type:"command",command:($hook + " usage")},
    hooks:{
      SessionStart:[{hooks:[{type:"command",command:($hook + " start")}]}],
      Stop:[{hooks:[{type:"command",command:($hook + " stop")},{type:"command",command:($hook + " cadence"),asyncRewake:true,timeout:28800}]}]
    }
  }'
  exit 0
fi
payload=$(cat)
session=$(jq -er '.session_id | select(type == "string" and length > 0)' <<< "$payload")
case "${1:-}" in
  start)
    mkdir -p "$STATE"
    request="$STATE/assistance-rotation.json"
    if [ -f "$request" ] && [ "$(jq -r '.session // empty' "$request" 2>/dev/null || true)" != "$session" ]; then
      rm -f "$request"
    fi
    printf '%s\n' "$session" > "$STATE/assistance-session"
    printf '%s\n' 'You are an assistance. Follow data/charter.md, not the supervisor role in AGENTS.md.'
    [ ! -f "$FM_HOME/data/assistance-handoff.md" ] || { printf '\nRead this previous-session handoff before checking sources:\n'; cat "$FM_HOME/data/assistance-handoff.md"; }
    ;;
  usage)
    jq -e '.context_window.context_window_size > 0' <<< "$payload" >/dev/null
    printf '%s\n' "$payload" > "$STATE/.assistance-usage.$$"
    mv "$STATE/.assistance-usage.$$" "$STATE/assistance-usage.json"
    printf 'assistance %s%%' "$(jq -r '.context_window.used_percentage // 0' <<< "$payload")"
    ;;
  stop)
    usage="$STATE/assistance-usage.json"
    [ -f "$usage" ] || { echo 'Assistance cannot measure context yet: statusLine usage is missing.' >&2; exit 2; }
    jq -e --arg session "$session" '.session_id == $session and .context_window.context_window_size > 0' "$usage" >/dev/null || exit 0
    pct=$(jq -r '.context_window.used_percentage // (((.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0)) * 100 / .context_window.context_window_size)' "$usage")
    if jq -en --argjson pct "$pct" '$pct >= 40' >/dev/null; then
      if [ ! -f "$STATE/assistance-rotation.json" ]; then
        jq -n --arg session "$session" --argjson at "$(date +%s)" '{session:$session,at:$at}' > "$STATE/assistance-rotation.json"
      fi
      # Once fresh stow/handoff exist, permit this turn to end so self-clear can
      # reach idle. Repeated requests converge under the rotation owner's lock.
      if "$SCRIPT_DIR/fm-assistance-rotate.sh" >/dev/null 2>&1; then exit 0; fi
      echo 'Assistance context reached 40%. Stow observations and source cursors into data/assistance-stow.md. Write data/assistance-handoff.md with Suggested skills and Next action, then run bin/fm-assistance-rotate.sh. Do not ask the parent to rotate you.' >&2
      exit 2
    fi
    ;;
  cadence)
    [ ! -f "$STATE/assistance-rotation.json" ] || exit 0
    # The durable source owner, not a private timer loop, captures the cadence.
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register assistance-cadence assistance-cadence -- "$SCRIPT_DIR/fm-procevent-assistance-cadence.sh" wait >/dev/null
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" start assistance-cadence >/dev/null
    [ "$(<"$STATE/assistance-session")" = "$session" ] || exit 0
    [ ! -f "$STATE/assistance-rotation.json" ] || exit 0
    echo 'Assistance cadence: run bin/fm-wake-drain.sh in this home to read the due procevent assistance-cadence sequence. After checking the profile sources, acknowledge it with bin/fm-procevent.sh handled assistance-cadence <sequence> and the exact --ack-through command printed by the drain. Investigate new evidence and propose only relevant work. This assistance uses its own cadence hook, not a parent supervision cycle; do not repair or start a fleet watcher.' >&2
    exit 2
    ;;
  *) echo 'error: expected start, usage, stop or cadence' >&2; exit 2 ;;
esac
