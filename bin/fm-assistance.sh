#!/usr/bin/env bash
# Persistent assistance homes, using the secondmate seed and spawn owners.
# Usage:
#   fm-assistance.sh start <name>
#   fm-assistance.sh stop <name> --captain
#   fm-assistance.sh recover
#   fm-assistance.sh propose <title> <why> <evidence>
#   fm-assistance.sh record <inbox-id>
# Profiles: config/assistances/<name>.json in the parent home. Required fields:
# name, charter, harness, model, effort, sources [{source,recipe}], cadence_seconds.
# Only Claude on Herdr is accepted until another adapter proves self-rotation.
# start enables and launches, or returns the existing endpoint without steering.
# stop is human-only (no detected harness ancestor/marker), disables restart and
# exits only the recorded assistance endpoint. It never removes the home.
# propose is assistance-only; record is parent-only and uses the hold wrapper.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
export FM_HOME
# shellcheck source=bin/fm-assistance-guard-lib.sh
. "$SCRIPT_DIR/fm-assistance-guard-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
DATA="$FM_HOME/data"
STATE="$FM_HOME/state"
REG="$DATA/assistances.md"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
valid_id() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || die 'invalid identifier'; }
help() { printf '%s\n' 'fm-assistance.sh start <name> | stop <name> --captain | recover' 'fm-assistance.sh propose <title> <why> <evidence> | record <inbox-id>'; }
profile() {
  valid_id "$1"
  PROFILE="$FM_HOME/config/assistances/$1.json"
  [ -f "$PROFILE" ] && [ ! -L "$PROFILE" ] || die "missing ordinary profile: $PROFILE"
  jq -e --arg name "$1" '
    .name == $name and .harness == "claude" and
    ([.charter,.model,.effort] | all(type == "string" and length > 0)) and
    (.cadence_seconds | type == "number" and floor == . and . >= 1 and . <= 27000) and
    (.sources | type == "array" and all(.[]; (.source | type == "string" and length > 0) and (.recipe | type == "string" and length > 0)))
  ' "$PROFILE" >/dev/null || die 'invalid assistance profile; only Claude self-rotation is supported'
}
assistance_home() {
  secondmate_registry_field "$REG" "$1" home || die "assistance is not registered: $1"
}
check_binding() {
  local name=$1 home=$2
  [ -f "$home/.fm-assistance-home" ] && [ "$(<"$home/.fm-assistance-home")" = "$name" ] || die 'assistance home identity mismatch'
  [ ! -e "$home/.fm-secondmate-home" ] || die 'assistance home has a secondmate identity'
}
start() {
  local name=$1 home meta status
  valid_id "$name"
  mkdir -p "$STATE"
  lock="$STATE/.assistance-start-$name.lock"
  fm_lock_acquire_wait "$lock"
  trap 'fm_lock_release "$lock"' EXIT
  fm_assistance_require_dispatcher || exit 1
  profile "$name"
  meta="$STATE/$name.meta"
  if [ -e "$meta" ]; then
    grep -qx 'kind=assistance' "$meta" || die 'identifier belongs to another task kind'
    status=$(fm_backend_agent_state "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")")
    case "$status" in
      alive)
        home=$(assistance_home "$name")
        check_binding "$name" "$home"
        printf 'enabled\n' > "$home/config/assistance-enabled"
        printf 'attached: %s\n' "$name"
        fm_lock_release "$lock"; trap - EXIT; return ;;
      dead|missing) ;;
      *) die "assistance endpoint cannot be safely classified: $status" ;;
    esac
  fi
  home=$(secondmate_registry_field "$REG" "$name" home 2>/dev/null || true)
  if [ -z "$home" ]; then
    mkdir -p "$DATA/$name"
    [ ! -e "$DATA/$name/brief.md" ] || die 'identifier has an existing brief'
    {
      printf '# Assistance role\n\nYou are an assistance, not a supervisor or worker.\n'
      printf 'Read data/assistance.json for your profile and data/assistance-handoff.md when present.\n'
      printf 'Observe sources read-only and investigate before proposing work.\n'
      printf 'Speak directly to the user in plain human language.\n'
      printf 'Write only private records in your own home and proposals through bin/fm-assistance.sh propose.\n'
      printf 'Run no fleet startup, dispatch, steering, merge, or project mutation.\n'
      printf 'On an assistance cadence notification, inspect the profile sources using their named recipes.\n'
      printf 'Use bin/fm-wake-drain.sh to read and acknowledge your own notifications.\n'
      printf 'At a rotation request, stow your observations and source cursors in data/, write data/assistance-handoff.md, then run bin/fm-assistance-rotate.sh.\n'
      printf 'The handoff must include ## Suggested skills and ## Next action.\n'
      printf '\n# Charter\n\n'
      jq -r .charter "$PROFILE"
      printf '\n# Routing scope\n\nObserve and propose only.\n'
      printf '\n# Project clones\n\nNone. This is a project-less domain.\n'
    } > "$DATA/$name/brief.md"
    "$SCRIPT_DIR/fm-home-seed.sh" --assistance "$name" - --no-projects
    home=$(assistance_home "$name")
  fi
  check_binding "$name" "$home"
  cp "$PROFILE" "$home/data/assistance.json"
  printf 'enabled\n' > "$home/config/assistance-enabled"
  "$SCRIPT_DIR/fm-spawn.sh" "$name" "$home" --assistance --backend herdr \
    --harness claude --model "$(jq -r .model "$PROFILE")" --effort "$(jq -r .effort "$PROFILE")"
  fm_lock_release "$lock"
  trap - EXIT
}
propose() {
  local name parent
  [ -f "$FM_HOME/.fm-assistance-home" ] || die 'proposal command requires an assistance home'
  name=$(<"$FM_HOME/.fm-assistance-home")
  valid_id "$name"
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-assistance-parent" || die 'assistance parent binding is invalid'
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || die 'assistance requires a local parent'
  parent=$FM_SECONDMATE_PARENT_HOME
  [ -d "$parent" ] || die 'assistance parent binding is unavailable'
  # Text is data, never a shell instruction. Only the parent records backlog work.
  jq -cn --arg assistance "$name" --arg title "$1" --arg why "$2" --arg evidence "$3" \
    '{assistance:$assistance,title:$title,why:$why,evidence:$evidence}' |
    FM_HOME="$parent" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
      "$SCRIPT_DIR/fm-inbox.sh" note -
}
record() {
  local id=$1 note payload name task title reason
  fm_assistance_require_dispatcher || exit 1
  valid_id "$id"
  note="$STATE/inbox/$id.note"
  [ -f "$note" ] && [ ! -L "$note" ] || die 'proposal note is unavailable'
  payload=$(awk 'body {print} $0 == "--" {body=1}' "$note")
  jq -e 'type == "object" and ([.assistance,.title,.why,.evidence] | all(type == "string" and length > 0))' <<< "$payload" >/dev/null || die 'not an assistance proposal'
  name=$(jq -r .assistance <<< "$payload")
  assistance_home "$name" >/dev/null
  task="proposal-$id"
  title=$(jq -r .title <<< "$payload")
  reason=$(jq -r '"Assistance " + .assistance + ": " + .why + " Evidence: " + .evidence' <<< "$payload")
  if ! "$SCRIPT_DIR/fm-tasks-axi.sh" show "$task" >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-tasks-axi.sh" add "$task" "$title"
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$task" --reason "$reason"
  "$SCRIPT_DIR/fm-inbox.sh" drain --ack "$id"
  printf 'held: %s\n' "$task"
}
case "${1:-}" in
  -h|--help|'') help ;;
  start) [ $# -eq 2 ] || die 'usage: fm-assistance.sh start <name>'; start "$2" ;;
  propose) [ $# -eq 4 ] || die 'usage: fm-assistance.sh propose <title> <why> <evidence>'; propose "$2" "$3" "$4" ;;
  record) [ $# -eq 2 ] || die 'usage: fm-assistance.sh record <inbox-id>'; record "$2" ;;
  recover)
    [ $# -eq 1 ] || die 'recover accepts no arguments'
    fm_assistance_require_dispatcher || exit 1
    [ -f "$REG" ] || exit 0
    failed=0
    while IFS= read -r line; do
      case "$line" in '- '*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || die 'invalid assistance registry'
      [ -f "$SECONDMATE_REGISTRY_HOME/config/assistance-enabled" ] || continue
      # One unavailable profile must not suppress other enabled homes.
      if ! "$SCRIPT_DIR/fm-assistance.sh" start "$SECONDMATE_REGISTRY_ID"; then failed=1; fi
    done < "$REG"
    exit "$failed"
    ;;
  stop)
    [ $# -eq 3 ] && [ "$3" = --captain ] || die 'usage: fm-assistance.sh stop <name> --captain'
    [ "$("$SCRIPT_DIR/fm-harness.sh")" = unknown ] || die 'assistance rule: only the captain may stop an assistance; run from a human terminal'
    valid_id "$2"
    home=$(assistance_home "$2")
    check_binding "$2" "$home"
    meta="$STATE/$2.meta"
    if [ ! -f "$meta" ] || ! grep -qx 'kind=assistance' "$meta"; then die 'assistance endpoint record unavailable'; fi
    [ "$(fm_meta_get "$meta" home)" = "$home" ] || die 'assistance endpoint home does not match the registry'
    target=$(fm_backend_target_of_meta "$meta")
    case "$(fm_backend_agent_state herdr "$target")" in
      dead|missing)
        rm -f "$home/config/assistance-enabled"
        printf 'stopped: %s (already stopped; home retained)\n' "$2"; exit 0 ;;
      alive) ;;
      *) die 'assistance process cannot be attributed; stop refused' ;;
    esac
    # Disable recovery before ending this exact process; preserve all home data.
    rm -f "$home/config/assistance-enabled"
    fm_backend_send_text_submit herdr "$target" /exit 3 0.2 1.2 >/dev/null || true
    for ((attempt=0; attempt<30; attempt++)); do
      case "$(fm_backend_agent_state herdr "$target")" in
        dead|missing) printf 'stopped: %s (home retained)\n' "$2"; exit 0 ;;
      esac
      sleep 1
    done
    die 'assistance stop was not confirmed; restart disabled and home retained'
    ;;
  *) die 'unknown command; run fm-assistance.sh --help' ;;
esac
