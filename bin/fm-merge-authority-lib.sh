#!/usr/bin/env bash
# Durable ownership of the authority under which a task's merge was accepted.
#
# The away-posture record (state/.afk-contract) is resolved only at the merge
# gate. Before a forge request, bin/fm-pr-merge.sh persists that answer on a
# PR event in 5001, bound to its URL and head. The merged event retains it.
# While an away record exists every merge runs under away authority (the
# record's presence is the whole mechanical fact; which merge the captain's
# away words meant is the supervision session's reading); without one, or while
# the record is quiet mode's (bin/fm-afk-contract.sh mode: the captain is
# present), the merge is attended. The retired values yolo and away-grant are
# still accepted when an existing record is read, so a merge persisted before
# the words model landed is still consumed, but they are never written again.
# The identity comes from the merge run's immutable canonical URL parse;
# persistence revalidates the task's current pr= metadata under its metadata
# and lifecycle locks and refuses a mismatch. A poll reads the recorded authority
# only for its canonical PR URL. Missing or mismatched records mean external;
# authority is never resolved again from a later away-posture record.
#
# Resolution authorizes nothing by itself. bin/fm-pr-merge.sh owns the merge
# gate and persists before a forge command, before releasing the
# task lifecycle lock. After observing a landed merge, bin/fm-watch.sh acquires
# that same lock, revalidates the poll, publishes its durable outcome, and
# retires only the exact authority record it read. Teardown uses the same lock,
# so it cannot interleave with that consumption transaction, and removes any
# remaining record.
#
# Sourced by those scripts and by tests. No side effects on source beyond its
# sourced libraries.

_FM_MERGE_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY_REASON=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_AUTHORITY_RECORD_IDENTITY=

fm_merge_authority_resolve() {  # <home> <state> <meta> <task-id>
  local home=${1-} state=${2-} meta=${3-} id=${4-}
  FM_MERGE_AUTHORITY=
  FM_MERGE_AUTHORITY_REASON='invalid'
  [ -n "$home" ] && [ -n "$state" ] && [ -n "$meta" ] && [ -n "$id" ] || return 1

  if ! fm_afk_contract_present "$state"; then
    FM_MERGE_AUTHORITY='attended'
    FM_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$_FM_MERGE_AUTHORITY_LIB_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1; then
    FM_MERGE_AUTHORITY_REASON='record-unreadable'
    return 1
  fi
  if ! fm_afk_contract_away_present "$state"; then
    FM_MERGE_AUTHORITY='attended'
    FM_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  FM_MERGE_AUTHORITY='away'
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_AUTHORITY_REASON='away'
  return 0
}

fm_merge_authority_record_matches() {  # <record> <device> <provider> <host> <path> <number>
  local record=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number authority
  fm_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 8< "$record" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r authority <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$authority" in away|attended|yolo|away-grant) ;; *) return 1 ;; esac
  [ "$version" = fm-merge-authority-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ] || return 1
  FM_MERGE_AUTHORITY=$authority
}

fm_merge_authority_persist() {  # <state> <task-id> <meta> <provider> <host> <path> <number> <authority>
  local state=$1 id=$2 meta=$3 provider=$4 host=$5 path=$6 number=$7 authority=$8
  local state_device
  fm_pr_task_id_valid "$id" || return 1
  case "$authority" in away|attended) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_META_HOST" = "$host" ] \
    && [ "$FM_PR_META_PATH" = "$path" ] \
    && [ "$FM_PR_META_NUMBER" = "$number" ] || return 1
  # The task event binds authority to the canonical PR identity, never to a local sidecar.
  local home=${FM_HOME:-$(dirname "$state")} head
  head=$(grep '^pr_head=' "$meta" | tail -1 | cut -d= -f2- || true)
  local -a args=(event "$id" pr --pr-url "$FM_PR_META_URL" --merge-authority "$authority"
    --key "merge-authority:$id:$provider:$host:$path:$number:${head:-unknown}:$authority")
  [ -z "$head" ] || args+=(--head "$head")
  FM_HOME="$home" "${FM_MERGE_AUTHORITY_TASK:-${FM_TASK_SHADOW_WRITER:-$_FM_MERGE_AUTHORITY_LIB_DIR/fm-task.sh}}" "${args[@]}" >/dev/null
  return $?
}

fm_merge_authority_read() {  # <state> <task-id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  FM_MERGE_AUTHORITY='external'
  FM_MERGE_AUTHORITY_RECORD_IDENTITY=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  local home=${FM_HOME:-$(dirname "$state")} result expected_url
  case "$provider" in
    github) expected_url="https://$host/$path/pull/$number" ;;
    forgejo) expected_url="https://$host/$path/pulls/$number" ;;
    gitlab) expected_url="https://$host/$path/-/merge_requests/$number" ;;
    *) return 1 ;;
  esac
  result=$(FM_HOME="$home" "${FM_MERGE_AUTHORITY_TASK:-${FM_TASK_SHADOW_WRITER:-$_FM_MERGE_AUTHORITY_LIB_DIR/fm-task.sh}}" pr-record "$id") || return 1
  [ "$(jq -r '.prUrl // empty' <<<"$result")" = "$expected_url" ] || return 1
  FM_MERGE_AUTHORITY=$(jq -r '.mergeAuthority // "external"' <<<"$result")
  case "$FM_MERGE_AUTHORITY" in away|attended) return 0 ;; *) return 1 ;; esac
}

fm_merge_authority_remove_if_matches() {  # <state> <task-id> <provider> <host> <path> <number> <authority> <file-identity>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  local authority=$7 expected_file_identity=$8 record state_device lock current_file_identity status=0
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    if fm_merge_authority_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number"; then
      current_file_identity=$(fm_pr_file_identity "$record") || status=1
      if [ "$status" -eq 0 ] \
        && [ "$FM_MERGE_AUTHORITY" = "$authority" ] \
        && [ "$current_file_identity" = "$expected_file_identity" ]; then
        rm -f -- "$record" || status=1
      fi
    elif ! fm_pr_private_file_valid "$record" 600 "$state_device"; then
      status=1
    fi
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}
