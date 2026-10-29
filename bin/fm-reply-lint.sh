#!/usr/bin/env bash
# Reply lint for replies to the captain, the Stop-hook transport (spec huynhtandat223/firstmate#200, E2).
#
# data/captain.md says what a reply to the captain looks like (line 16: reply in
# Vietnamese, technical terms stay English; line 20: decisions go to the board
# with agent-ask), but a rule written only as text kept being broken. This hook
# reads the turn that just ended and names the broken rule. bin/fm-reply-lint.mjs
# owns the checks and the fix text each one prints:
#   english  no Vietnamese letter and 20+ Latin letters in the reply
#   question a `?` in the last 400 characters and no agent-ask call in the turn
#   notes    captain notes wait in state/inbox/
#   unread   data/captain.md was not read since the last SessionStart
#
# Switches (config/, bin/fm-enforce-lib.sh owns the log-only rule):
#   config/reply-language   the first non-comment line, `vi` today. Absent = the
#                           lint is off, so other firstmate users are unaffected.
#   config/enforce-reply-lint  `block` makes a hit block the turn end (exit 2 and
#                           the message on stderr). Anything else, or no file,
#                           only appends the hit to state/enforce-reply-lint.log.
#
# Once per user turn: a block is remembered in state/.reply-lint-blocked.<session_id>
# by the uuid of the user prompt that started the turn (line 2) and the uuid of
# the reply it blocked (line 1). A later Stop of the same user turn
# (stop_hook_active) is allowed, however many continuations another Stop hook
# forces and whatever uuid the blocked reply carried, so a turn is never blocked
# twice and never wedged. A transcript with no user prompt row falls back to the
# reply uuid: the Stop that directly follows the blocked reply is allowed.
#
# Usage:
#   <Stop JSON on stdin> | bin/fm-reply-lint.sh --claude
#   bin/fm-reply-lint.sh --replay <transcript.jsonl> [--language vi]   list every turn end the lint would flag
#
# Scope: a genuine primary home only (bin/fm-primary-scope-lib.sh), like
# bin/fm-turnend-guard.sh. FAIL OPEN: a missing jq, node, transcript or payload
# allows the turn end.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CORE="$SCRIPT_DIR/fm-reply-lint.mjs"

# The language from config/reply-language, or empty when the lint is off.
reply_language() {
  local line word
  [ -f "$CONFIG/reply-language" ] && [ -r "$CONFIG/reply-language" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    word=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$word" in
      ''|'#'*) continue ;;
      *) printf '%s' "$word"; return 0 ;;
    esac
  done < "$CONFIG/reply-language"
}

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --replay)
    [ -n "${2:-}" ] || { echo "usage: fm-reply-lint.sh --replay <transcript.jsonl> [--language vi]" >&2; exit 2; }
    transcript=$2
    language='vi'
    [ "${3:-}" != --language ] || language=${4:-vi}
    command -v node >/dev/null 2>&1 || { echo "fm-reply-lint: node is required for --replay" >&2; exit 1; }
    exec node "$CORE" --transcript "$transcript" --replay --language "$language"
    ;;
  --claude) ;;
  *) echo "usage: fm-reply-lint.sh --claude | --replay <transcript.jsonl>" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0
[ -f "$CORE" ] || exit 0
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-enforce-lib.sh
. "$SCRIPT_DIR/fm-enforce-lib.sh"

LANGUAGE=$(reply_language)
[ -n "$LANGUAGE" ] || exit 0

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
STOP_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || STOP_ACTIVE=false
LAST_TEXT=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null) || LAST_TEXT=

ARGS=(--transcript "$TRANSCRIPT" --last --language "$LANGUAGE" --inbox-dir "$STATE/inbox" --home "$FM_HOME")
[ -z "$LAST_TEXT" ] || ARGS+=(--last-text "$LAST_TEXT")
RESULT=$(node "$CORE" "${ARGS[@]}" 2>/dev/null) || exit 0
[ -n "$RESULT" ] || exit 0

TAB=$(printf '\t')
HEADER=$(printf '%s\n' "$RESULT" | sed -n '1p')
case "$HEADER" in "stop${TAB}"*) ;; *) exit 0 ;; esac
rest=${HEADER#stop"$TAB"}
STOP_UUID=${rest%%"$TAB"*}
rest=${rest#*"$TAB"}
PREV_UUID=${rest%%"$TAB"*}
TURN=
case "$rest" in *"$TAB"*) TURN=${rest#*"$TAB"} ;; esac
FINDINGS=$(printf '%s\n' "$RESULT" | sed '1d')
[ -n "$FINDINGS" ] || exit 0

# A later stop of the user turn the lint already blocked in this session.
SESSION_KEY=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')
BLOCKED_FILE="$STATE/.reply-lint-blocked.${SESSION_KEY:-unknown}"
if [ "$STOP_ACTIVE" = true ] && [ -f "$BLOCKED_FILE" ]; then
  BLOCKED_UUID=$(sed -n '1p' "$BLOCKED_FILE" 2>/dev/null)
  BLOCKED_TURN=$(sed -n '2p' "$BLOCKED_FILE" 2>/dev/null)
  if { [ -n "$TURN" ] && [ "$BLOCKED_TURN" = "$TURN" ]; } || { [ -n "$PREV_UUID" ] && [ "$BLOCKED_UUID" = "$PREV_UUID" ]; }; then
    fm_enforce_log "$STATE" reply-lint second-stop - "$STOP_UUID"
    exit 0
  fi
fi

MODE=$(fm_enforce_mode "$CONFIG" reply-lint)
MESSAGE=
while IFS="$TAB" read -r _uuid code text; do
  [ -n "$code" ] || continue
  fm_enforce_log "$STATE" reply-lint "$([ "$MODE" = block ] && echo block || echo would-block)" "$code" "$text"
  MESSAGE="${MESSAGE}reply lint [$code] $text"$'\n'
done <<< "$FINDINGS"

[ "$MODE" = block ] || exit 0
[ -n "$MESSAGE" ] || exit 0
# Write the record whole or not at all: a torn file would read as another reply's uuid.
if mkdir -p "$STATE" 2>/dev/null && printf '%s\n%s\n' "$STOP_UUID" "$TURN" > "$BLOCKED_FILE.tmp.$$" 2>/dev/null \
  && mv -f "$BLOCKED_FILE.tmp.$$" "$BLOCKED_FILE" 2>/dev/null; then
  :
else
  rm -f "$BLOCKED_FILE.tmp.$$" 2>/dev/null
  exit 0
fi
printf '%s' "$MESSAGE" >&2
exit 2
