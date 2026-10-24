#!/usr/bin/env bash
# shellcheck disable=SC2034 # DELIVER_ERROR and DELIVER_BASE are read by the sourcing adapter
# Shared by the built-in process-event adapters that send assistances their source records
# (bin/fm-procevent-deploy-verify.sh, bin/fm-procevent-pr-review.sh): one GitHub read, one
# JSONL ledger, one poll throttle, one delivery of an fm-assistance-mentions.v1 record, and
# one acknowledgement of older results. Source it; it runs nothing on its own.
#
# The adapter sets these before it calls any function:
#   SCRIPT_DIR FM_HOME STATE SOURCE_ID
#   GH                 the gh command
#   READ_ERROR_FILE    where a failed GitHub read leaves its reason
#   LEDGER             the JSONL ledger
#   LAST_POLL          the file holding the epoch of the last poll
#   POLL_SECONDS       the least time between two polls
#
# gh_read <api-path>            the answer on stdout; a failure leaves its reason in READ_ERROR_FILE
# ledger_test <jq-expr> [args]  exit 0 when any ledger line matches the jq boolean expression
# ledger_append <json>          add one ledger line
# throttle                      sleep until POLL_SECONDS have passed since the last poll
# mark_handled <sequence>       acknowledge this result and every older unacknowledged one, except an
#                               older result keep_pending_result accepts
# keep_pending_result <result-file>
#                               the adapter may define it; exit 0 means this older result was left
#                               unhandled on purpose for firstmate to read, so the catch-up leaves it
#                               and its queued wake row alone. The default keeps nothing.
# deliver_record <label> <assistance> <record-json>
#                               write the record into the assistance home's data/pending-mentions/
#                               and announce it with `fm-assistance.sh source-event`. Success sets
#                               DELIVER_BASE (the record basename). A refusal removes the record and
#                               sets DELIVER_ERROR to "<label> ask not delivered: <reason>".

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

gh_read() {
  local out
  if ! out=$("$GH" api "$1" 2>/dev/null) || [ -z "$out" ]; then
    printf 'GitHub could not be read: %s\n' "${1%%\?*}" > "$READ_ERROR_FILE"
    return 1
  fi
  printf '%s\n' "$out"
}

ledger_test() {
  local expr=$1
  shift
  [ -s "$LEDGER" ] || return 1
  jq -se "$@" "any(.[]; $expr)" "$LEDGER" >/dev/null 2>&1
}
ledger_append() { printf '%s\n' "$1" >> "$LEDGER"; }

throttle() {
  local last now wait_for
  [ -f "$LAST_POLL" ] || return 0
  last=$(<"$LAST_POLL")
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  wait_for=$((POLL_SECONDS - (now - last)))
  [ "$wait_for" -le 0 ] || sleep "$wait_for"
}

keep_pending_result() { return 1; }

mark_handled() {
  local seq=$1 pending s
  while IFS= read -r pending; do
    [ -n "$pending" ] || continue
    s=${pending%.result}
    s=${s##*.}
    case "$s" in ''|*[!0-9]*) continue ;; esac
    [ "$s" -le "$seq" ] || continue
    [ "$s" -eq "$seq" ] || ! keep_pending_result "$pending" || continue
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$s" >/dev/null 2>&1 || true
  done < <(fm_procevent_pending "$STATE" | grep "/$SOURCE_ID\\.")
}

DELIVER_ERROR=
DELIVER_BASE=
deliver_record() {
  local label=$1 assistance=$2 record=$3 home digest base pending_dir err out
  DELIVER_BASE=
  if ! home=$(secondmate_registry_field "$FM_HOME/data/assistances.md" "$assistance" home 2>/dev/null) || [ -z "$home" ]; then
    DELIVER_ERROR="$label ask not delivered: assistance $assistance is not registered"
    return 1
  fi
  digest=$(jq -c '.messages | map([.id, .arrival])' <<<"$record" | sha256sum | cut -d' ' -f1)
  base="$digest.json"
  pending_dir="$home/data/pending-mentions"
  if ! mkdir -p "$pending_dir" 2>/dev/null \
    || ! printf '%s\n' "$record" > "$pending_dir/.$base.tmp" 2>/dev/null \
    || ! mv -f "$pending_dir/.$base.tmp" "$pending_dir/$base" 2>/dev/null; then
    rm -f "$pending_dir/.$base.tmp" 2>/dev/null
    DELIVER_ERROR="$label ask not delivered: the $label pending record could not be written"
    return 1
  fi
  if ! out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-assistance.sh" source-event "$assistance" "$base" 2>&1); then
    rm -f "$pending_dir/$base"
    err=$(printf '%s\n' "$out" | grep -m1 '^error:' | cut -c1-160)
    DELIVER_ERROR="$label ask not delivered: ${err:-source-event refused}"
    return 1
  fi
  DELIVER_BASE=$base
}
