#!/usr/bin/env bash
# PreToolUse transport for the drain-and-ack guard (spec huynhtandat223/firstmate#200, E3).
#
# One Bash command that runs `fm-wake-drain.sh --ack-through` together with any
# other `fm-wake-drain.sh` acknowledges rows the same command only just printed,
# so nothing was read between the drain and its ack. bin/fm-drain-command-policy.mjs
# is the sole owner of the deny/log/allow decision and reuses the shell classifier
# of bin/fm-arm-command-policy.mjs. This wrapper scopes the guard to the real
# primary checkout like bin/fm-cd-pretool-check.sh, reads the harness payload,
# applies the log-only switch, and renders the Claude deny response. It never
# executes, sources or expands the command.
#
# Log-only switch (bin/fm-enforce-lib.sh): a deny is written to
# state/enforce-drain-ack.log and the command is allowed until
# config/enforce-drain-ack holds `block`. A `log` decision (a drain piped into
# grep, head, cut or sed) is only ever logged, in both modes.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-drain-pretool-check.sh --claude
#   bin/fm-drain-pretool-check.sh --command '<cmd>' [--claude]
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
Usage: fm-drain-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin.
Fires only in the real primary firstmate checkout.
Exits 2 to deny a command that acks and drains together, only when
config/enforce-drain-ack holds `block`; otherwise the hit is written to
state/enforce-drain-ack.log and the command is allowed.
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

# Prefilter (transport only): a command that never names the drain script
# cannot be classified as a drain, so skip Node for it.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *fm-wake-drain*) ;;
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

POLICY="$FM_ROOT/bin/fm-drain-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
case "$DECISION" in deny|log) ;; *) exit 0 ;; esac
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

HOME_DIR=${FM_HOME:-$FM_ROOT}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-$HOME_DIR/config}
STATE_DIR=${FM_STATE_OVERRIDE:-$HOME_DIR/state}
# shellcheck source=bin/fm-enforce-lib.sh
. "$SCRIPT_DIR/fm-enforce-lib.sh"

MODE=$(fm_enforce_mode "$CONFIG_DIR" drain-ack)
if [ "$DECISION" = log ] || [ "$MODE" != block ]; then
  fm_enforce_log "$STATE_DIR" drain-ack "$([ "$DECISION" = deny ] && echo would-deny || echo log)" "$CODE" "$CMD"
  exit 0
fi
fm_enforce_log "$STATE_DIR" drain-ack deny "$CODE" "$CMD"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "[$CODE] $REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
