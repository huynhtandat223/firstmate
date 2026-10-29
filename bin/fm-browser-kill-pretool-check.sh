#!/usr/bin/env bash
# PreToolUse transport for the browser kill guard (spec huynhtandat223/firstmate#200, E4b).
#
# Firstmate once killed chrome-devtools processes by pid or by age and closed the
# captain's 9222 and 9333 Chromes and the Tester's browser mid-round. A kill,
# pkill or killall aimed at a browser breaks that rule.
# bin/fm-browser-kill-command-policy.mjs is the sole owner of the deny/allow
# decision and reuses the shell classifier of bin/fm-arm-command-policy.mjs.
# This wrapper scopes the guard to the real primary checkout like
# bin/fm-cd-pretool-check.sh, resolves which pids listen on a watched port or
# run a browser, reads the harness payload, applies the log-only switch, and
# renders the Claude deny response. It never executes, sources or expands the
# command.
#
# Watched ports: 9222, 9333 and every port in config/browser-ports (one per
# line; blank lines and # comments ignored; put the Tester's port there).
#
# Log-only switch (bin/fm-enforce-lib.sh): a deny is written to
# state/enforce-browser-kill.log and the command is allowed until
# config/enforce-browser-kill holds `block`.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-browser-kill-pretool-check.sh --claude
#   bin/fm-browser-kill-pretool-check.sh --command '<cmd>' [--claude]
#
# Exit/output contract (same shape as bin/fm-cd-pretool-check.sh):
#   ALLOW or log-only - exit 0 and no output.
#   DENY (block mode) - exit 2 and a Claude-shaped deny object on stderr, plus a
#          Grok-shaped deny object on stdout unless --claude was supplied.
#   INERT - not the real primary checkout (a task worktree or another repo).
#   FAIL OPEN - malformed or empty stdin, missing jq, Node or the policy file.
# Only Claude registers this check today (.claude/settings.json).
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF2'
Usage: fm-browser-kill-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin.
Fires only in the real primary firstmate checkout.
Exits 2 to deny a kill aimed at a browser, only
when config/enforce-browser-kill holds `block`; otherwise the hit is written to
state/enforce-browser-kill.log and the command is allowed.
EOF2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Prefilter (transport only): a command that names no kill and no fuser
# cannot be classified as a browser kill, so skip Node for it.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *kill*|*fuser*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

POLICY="$FM_ROOT/bin/fm-browser-kill-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

HOME_DIR=${FM_HOME:-$FM_ROOT}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}
STATE_DIR=${FM_STATE_OVERRIDE:-$HOME_DIR/state}

PORTS="9222 9333"
if [ -r "$CONFIG_DIR/browser-ports" ]; then
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    LINE=${LINE%%#*}
    LINE=$(printf '%s' "$LINE" | tr -d '[:space:]')
    case "$LINE" in
      ''|*[!0-9]*) continue ;;
    esac
    PORTS="$PORTS $LINE"
  done < "$CONFIG_DIR/browser-ports"
fi

# Pids that listen on a watched port, and pids that run a browser (chrome,
# chromium, or the chrome-devtools bridge). Read only: ss and ps.
browser_pids() {
  {
    if command -v ss >/dev/null 2>&1; then
      ss -ltnpH 2>/dev/null | awk -v ports=" $PORTS " '{ n = split($4, a, ":"); if (index(ports, " " a[n] " ")) print }' \
        | grep -o 'pid=[0-9]*' | cut -d= -f2
    fi
    ps -eo pid=,args= 2>/dev/null | awk -v self="$$" '
      $1 == self { next }
      { exe = $2; sub(/.*\//, "", exe) }
      exe ~ /^(google-)?chrome(-sandbox)?$/ || exe ~ /^chromium/ || $0 ~ /chrome-devtools-(mcp|axi)/ { print $1 }'
  } | sort -un | paste -sd, -
}

PORT_LIST=$(printf '%s' "$PORTS" | tr ' ' ',')
PID_LIST=$(browser_pids)
POLICY_OUTPUT=$(node "$POLICY" --ports "$PORT_LIST" ${PID_LIST:+--pids "$PID_LIST"} --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = deny ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

# shellcheck source=bin/fm-enforce-lib.sh
. "$SCRIPT_DIR/fm-enforce-lib.sh"

MODE=$(fm_enforce_mode "$CONFIG_DIR" browser-kill)
if [ "$MODE" != block ]; then
  fm_enforce_log "$STATE_DIR" browser-kill would-deny "$CODE" "$CMD"
  exit 0
fi
fm_enforce_log "$STATE_DIR" browser-kill deny "$CODE" "$CMD"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "[$CODE] $REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
