#!/usr/bin/env bash
# fm-primary-inject.sh - the guarded owner of typed primary-session injection.
#
# Callers own when injection is allowed. This owner owns the complete delivery
# boundary after that decision: one-line collapse, typed encoding, target
# existence, busy state, confirmed-empty composer, and confirmed submit.
#
# Sourcing is side-effect free. It expects bin/fm-backend.sh and
# bin/fm-operational-input.sh to be available, and sources them when needed.

FM_PRIMARY_INJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_PRIMARY_INJECT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$FM_PRIMARY_INJECT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_PRIMARY_INJECT_DIR/fm-composer-lib.sh"

fm_primary_inject_collapse_newlines() {  # <text>
  local text=$1
  text=${text//$'\n'/ - }
  printf '%s' "$text"
}

fm_primary_inject_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  fi
}

fm_primary_inject_busy() {  # <backend> <target>
  local backend=$1 target=$2 native tail harness
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  [ "$native" = busy ] && return 0
  if declare -F pane_is_busy >/dev/null 2>&1; then
    pane_is_busy "$target" "$backend"
    return $?
  fi
  tail=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  harness=${FM_DAEMON_PRIMARY_HARNESS:-}
  if [ -z "$harness" ] && [ -x "$FM_PRIMARY_INJECT_DIR/fm-harness.sh" ]; then
    harness=$("$FM_PRIMARY_INJECT_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
  fi
  printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match "${harness:-unknown}"
}

# fm_primary_rotate: <backend> <target> <handoff>
#
# Replace the bound primary's in-process session through its own supported
# session command, then submit the captain's fixed continuation prompt. This
# is the sole lifecycle action assistance may request.
fm_primary_rotate() {
  local backend=$1 target=$2 handoff=$3 harness command prompt verdict
  if [ -n "${FM_PRIMARY_ROTATE:-}" ]; then
    "$FM_PRIMARY_ROTATE" "$backend" "$target" "$handoff"
    return $?
  fi
  harness=${FM_DAEMON_PRIMARY_HARNESS:-}
  [ -n "$harness" ] || harness=$("$FM_PRIMARY_INJECT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  command=$("$FM_PRIMARY_INJECT_DIR/fm-harness.sh" primary-rotation-command "$harness")
  case "$command" in
    /clear|/new) ;;
    *) fm_primary_inject_log "primary rotation refused: harness $harness has no measured session replacement command"; return 1 ;;
  esac
  fm_backend_target_exists "$backend" "$target" || return 1
  fm_backend_send_text_submit "$backend" "$target" "$command" "${FM_INJECT_CONFIRM_RETRIES:-3}" "${FM_INJECT_CONFIRM_SLEEP:-0.5}" "${FM_INJECT_CONFIRM_SLEEP:-0.5}" >/dev/null || return 1
  prompt="$handoff you're orchestrator, continue your work"
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$prompt" "${FM_INJECT_CONFIRM_RETRIES:-3}" "${FM_INJECT_CONFIRM_SLEEP:-0.5}" "${FM_INJECT_CONFIRM_SLEEP:-0.5}") || return 1
  [ "$verdict" = empty ]
}

# fm_primary_inject: <kind> <backend> <target> <message>
#
# The caller must perform any policy or presence gate before calling this
# function. The kind is closed by fm-operational-input.sh, so each delivery is
# structurally distinguishable at the receiving primary.
fm_primary_inject() {
  local kind=$1 backend=$2 target=$3 message=$4 encoded composer retries sleep_s verdict

  if [ "$kind" = assistance ] && [ -n "${FM_PRIMARY_HANDOFF:-}" ]; then
    "$FM_PRIMARY_HANDOFF" "$backend" "$target" "$message"
    return $?
  fi
  message=$(fm_primary_inject_collapse_newlines "$message")
  fm_operational_input_encode "$kind" "$message" encoded || return 1
  fm_backend_target_exists "$backend" "$target" || return 1

  if fm_primary_inject_busy "$backend" "$target"; then
    fm_primary_inject_log "inject deferred: primary pane busy (agent mid-turn)"
    return 1
  fi

  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    fm_primary_inject_log "inject deferred: primary composer not confirmed-empty (state=${composer:-unknown})"
    return 1
  fi

  retries=${FM_INJECT_CONFIRM_RETRIES:-3}
  sleep_s=${FM_INJECT_CONFIRM_SLEEP:-0.5}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$encoded" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    return 0
  fi
  fm_primary_inject_log "inject failed: submit unconfirmed after $retries retries (verdict=$verdict)"
  return 1
}

# Resolve the live primary pane from the home lock holder's inherited runtime
# markers. An explicit override is useful for operators and isolated tests.
# Prints <backend><TAB><target> and refuses when the primary identity is not
# discoverable rather than guessing another pane.
fm_primary_target_from_home() {  # <fm-home>
  local home=$1 state lock_pid env_file line tmux_pane herdr_pane herdr_session
  if [ -n "${FM_PRIMARY_TARGET:-}" ]; then
    printf '%s\t%s\n' "${FM_PRIMARY_BACKEND:-tmux}" "$FM_PRIMARY_TARGET"
    return 0
  fi
  state="$home/state"
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  env_file="/proc/$lock_pid/environ"
  [ -r "$env_file" ] || return 1
  while IFS= read -r -d '' line; do
    case "$line" in
      TMUX_PANE=*) tmux_pane=${line#TMUX_PANE=} ;;
      HERDR_PANE_ID=*) herdr_pane=${line#HERDR_PANE_ID=} ;;
      HERDR_SESSION=*) herdr_session=${line#HERDR_SESSION=} ;;
    esac
  done < "$env_file"
  if [ -n "${tmux_pane:-}" ]; then
    printf 'tmux\t%s\n' "$tmux_pane"
    return 0
  fi
  if [ -n "${herdr_pane:-}" ]; then
    printf 'herdr\t%s:%s\n' "${herdr_session:-default}" "$herdr_pane"
    return 0
  fi
  return 1
}
