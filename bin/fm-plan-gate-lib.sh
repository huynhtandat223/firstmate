#!/usr/bin/env bash
# Dispatch plan approval protocol. Source this library, then call
# fm_plan_gate_check <https://github.com/owner/repo/issues/number>.
# FM_PLAN_GATE_VERDICT and FM_PLAN_GATE_REASON describe the result.
# Only the newest comment with first line matching
# ^approved: firstmate [0-9]+ body-sha256:[0-9a-f]{64}$ counts.
# Reads use FM_PLAN_GATE_TIMEOUT_SECS (default 20) through fm_run_timed.
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

fm_plan_gate_url() {
  if [[ $1 =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9][0-9]*)$ ]]; then
    FM_PLAN_GATE_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    FM_PLAN_GATE_ISSUE_REPO=$FM_PLAN_GATE_REPO
    FM_PLAN_GATE_ISSUE_NUMBER=${BASH_REMATCH[3]}
    FM_PLAN_GATE_PATH="repos/$FM_PLAN_GATE_REPO/issues/${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

fm_plan_gate_read() {
  fm_run_timed "${FM_PLAN_GATE_TIMEOUT_SECS:-20}" gh api "$@" --hostname github.com
}

fm_plan_gate_task() (
  . "$FM_PLAN_GATE_ROOT/bin/fm-task-shadow-config-lib.sh"
  fm_task_shadow_config "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_PLAN_GATE_ROOT}/config}/task-shadow"
  "$FM_PLAN_GATE_ROOT/bin/fm-task.sh" "$@"
)

fm_plan_gate_issue() {  # <issue-url> [--any-state]; a closed issue still yields its spec
  local any_state=${2:-}
  FM_PLAN_GATE_VERDICT=error
  if [[ $1 != https://github.com/*/issues/* ]]; then
    FM_PLAN_GATE_TASK=$1
    if [[ $1 == *task=* ]]; then FM_PLAN_GATE_TASK=${1##*task=}; FM_PLAN_GATE_TASK=${FM_PLAN_GATE_TASK%%&*}; fi
    FM_PLAN_GATE_BODY=$(fm_plan_gate_task document "$FM_PLAN_GATE_TASK") || { FM_PLAN_GATE_REASON='task Description read failed'; return 1; }
    FM_PLAN_GATE_HASH=$(printf '%s' "$FM_PLAN_GATE_BODY" | shasum -a 256 | cut -d' ' -f1)
    FM_PLAN_GATE_ISSUE_REPO=tasks
    FM_PLAN_GATE_ISSUE_NUMBER=$FM_PLAN_GATE_TASK
    return 0
  fi
  FM_PLAN_GATE_TASK=
  FM_PLAN_GATE_VERDICT=error
  FM_PLAN_GATE_REASON='GitHub issue read error'
  fm_plan_gate_url "$1" || { FM_PLAN_GATE_VERDICT=not-issue; FM_PLAN_GATE_REASON='not a GitHub issue URL'; return 1; }
  local issue
  issue=$(fm_plan_gate_read "$FM_PLAN_GATE_PATH" 2>&1) || { FM_PLAN_GATE_REASON="GitHub read error or timeout: $issue"; return 1; }
  if ! printf '%s' "$issue" | jq -e 'type == "object" and (.state | type == "string") and (.body == null or (.body | type == "string"))' >/dev/null 2>&1; then
    FM_PLAN_GATE_REASON='invalid GitHub issue response'
    return 1
  fi
  if printf '%s' "$issue" | jq -e 'has("pull_request")' >/dev/null; then
    FM_PLAN_GATE_VERDICT=not-issue
    FM_PLAN_GATE_REASON='not-issue: URL identifies a pull request'
    return 1
  fi
  FM_PLAN_GATE_BODY=$(printf '%s' "$issue" | jq -r '.body // ""')
  if [ "$any_state" != --any-state ] && [ "$(printf '%s' "$issue" | jq -r .state)" != open ]; then
    FM_PLAN_GATE_VERDICT=closed
    FM_PLAN_GATE_REASON='issue is closed'
    return 1
  fi
  FM_PLAN_GATE_HASH=$(printf '%s' "$issue" | jq -j '.body // ""' | shasum -a 256 | cut -d' ' -f1)
}

fm_plan_gate_check() {
  fm_plan_gate_issue "$1" || return 1
  if [ -n "${FM_PLAN_GATE_TASK:-}" ]; then
    fm_plan_gate_task plan-check "$FM_PLAN_GATE_TASK" >/dev/null || { FM_PLAN_GATE_VERDICT=unapproved; FM_PLAN_GATE_REASON='task plan unapproved or changed'; return 1; }
    FM_PLAN_GATE_VERDICT=approved
    FM_PLAN_GATE_REASON=approved
    return 0
  fi
  local comments marker
  comments=$(fm_plan_gate_read "$FM_PLAN_GATE_PATH/comments" --paginate 2>&1) || {
    FM_PLAN_GATE_VERDICT=error
    FM_PLAN_GATE_REASON="GitHub comment read error or timeout: $comments"
    return 1
  }
  marker=$(printf '%s' "$comments" | jq -rs '
    [ .[] | .[] | select(.body | type == "string") |
      . + {first:(.body | split("\n")[0])} |
      select(.first | test("^approved: firstmate [0-9]+ body-sha256:[0-9a-f]{64}$")) ] |
    sort_by(.id) | last | .first // ""') || {
    FM_PLAN_GATE_VERDICT=error
    FM_PLAN_GATE_REASON='invalid GitHub comments response'
    return 1
  }
  if [ -z "$marker" ]; then
    FM_PLAN_GATE_VERDICT=unapproved
    FM_PLAN_GATE_REASON='issue has no approval'
    return 1
  fi
  if [ "${marker##*body-sha256:}" != "$FM_PLAN_GATE_HASH" ]; then
    FM_PLAN_GATE_VERDICT=changed
    FM_PLAN_GATE_REASON='plan changed since approval; needs re-approval'
    return 1
  fi
  FM_PLAN_GATE_VERDICT=approved
  FM_PLAN_GATE_REASON=approved
}

# The spec of an issue, and the one-ticket-per-repository and two-specs-in-flight
# gates, from the same body fm_plan_gate_issue already read. One owner for the
# three parent forms the Planner template allows.
FM_PLAN_GATE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fm_plan_gate_spec_of_body() {  # <repo> <number> <body>; prints the canonical spec URL
  local repo=$1 number=$2 body=${3:-} ref parent
  parent=$(printf '%s\n' "$body" | awk '
    /^##[[:space:]]+Parent/ { inside = 1; next }
    /^##[[:space:]]/ { if (inside) exit }
    inside { print }')
  ref=$(printf '%s\n' "$parent" | grep -oE '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' | head -n 1 || true)
  if [ -z "$ref" ]; then
    ref=$(printf '%s\n' "$body" | grep -E '^- Parent:' | grep -oE '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' | head -n 1 || true)
  fi
  case "$ref" in
    '') printf 'https://github.com/%s/issues/%s\n' "$repo" "$number" ;;
    '#'*) printf 'https://github.com/%s/issues/%s\n' "$repo" "${ref#\#}" ;;
    *) printf 'https://github.com/%s/issues/%s\n' "${ref%%#*}" "${ref##*#}" ;;
  esac
}

fm_plan_gate_spec() {  # <issue-url> | reads the body fm_plan_gate_issue fetched; sets FM_PLAN_GATE_SPEC
  if [ -n "${FM_PLAN_GATE_TASK:-}" ]; then
    FM_PLAN_GATE_SPEC=$FM_PLAN_GATE_TASK
    return 0
  fi
  [ -n "${FM_PLAN_GATE_ISSUE_REPO:-}" ] && [ -n "${FM_PLAN_GATE_ISSUE_NUMBER:-}" ] || return 1
  FM_PLAN_GATE_SPEC=$(fm_plan_gate_spec_of_body "$FM_PLAN_GATE_ISSUE_REPO" "$FM_PLAN_GATE_ISSUE_NUMBER" "${FM_PLAN_GATE_BODY:-}")
  [ -n "$FM_PLAN_GATE_SPEC" ]
}

fm_plan_gate_repos() {  # <approved-issue-repo>; prints each counted repository once
  local repo=$1 file line
  file="${FM_PLAN_GATE_CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_PLAN_GATE_ROOT}/config}}/plan-gate-repos"
  printf '%s\n' "$repo"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      case "$line" in ''|*/*) ;; *) continue ;; esac
      [ -z "$line" ] || printf '%s\n' "$line"
    done < "$file"
  else
    printf '%s\n' huynhtandat223/cfw-modules huynhtandat223/firstmate
  fi | awk 'NF && !seen[$0]++'
}

fm_plan_gate_one_per_repo() {  # <approved-issue-repo> <spec-url>; refuses a split spec, prints one line per repository
  local approved_repo=$1 spec=$2 repo list number body spec_of status=0 spec_repo spec_number
  [ "$approved_repo" != tasks ] || return 0
  [ -n "$approved_repo" ] && [ -n "$spec" ] || return 1
  spec_repo=$(printf '%s' "$spec" | sed 's#^https://github.com/##; s#/issues/.*$##')
  spec_number=${spec##*/}
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if ! list=$(fm_plan_gate_read "repos/$repo/issues?state=open&per_page=100" --paginate 2>&1); then
      printf 'error: plan gate: GitHub read error or timeout: %s\n' "$list" >&2
      return 1
    fi
    if ! printf '%s' "$list" | jq -e 'if type == "array" then all(.[]; type == "object") else (type == "object") end' >/dev/null 2>&1; then
      printf 'error: plan gate: invalid GitHub issues response for %s\n' "$repo" >&2
      return 1
    fi
    local -a members=()
    while IFS=$'\t' read -r number body; do
      [ -n "${number:-}" ] || continue
      if [ "$repo" = "$spec_repo" ] && [ "$number" = "$spec_number" ]; then
        continue
      fi
      spec_of=$(fm_plan_gate_spec_of_body "$repo" "$number" "$(printf '%s' "$body" | base64 -d)")
      [ "$spec_of" = "$spec" ] || continue
      members+=("#$number")
    done < <(printf '%s' "$list" | jq -r '
      (if type == "array" then . else [.] end)
      | .[] | select(type == "object")
      | select((.pull_request // null) == null)
      | select((.state // "open") == "open")
      | select((.number // null) != null)
      | "\(.number)\t\((.body // "") | @base64)"')
    if [ "${#members[@]}" -gt 1 ]; then
      printf 'error: plan gate: spec %s has %s open tickets in %s (%s); fold them into one ticket with a ## Steps checklist (Planner) before approval\n' \
        "$spec" "${#members[@]}" "$repo" "$(printf '%s, ' "${members[@]}" | sed 's/, $//')" >&2
      status=1
    fi
  done < <(fm_plan_gate_repos "$approved_repo")
  return "$status"
}

fm_plan_gate_in_flight_specs() {  # <state-dir> <excluded-task>; sets "<spec>\t<task>" lines in FM_PLAN_GATE_IN_FLIGHT
  local state=$1 exclude=$2 meta task kind plan_issue plan_spec
  FM_PLAN_GATE_IN_FLIGHT=""
  FM_PLAN_GATE_IN_FLIGHT_COUNT=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta" .meta)
    [ "$task" = "$exclude" ] && continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
    [ "$kind" = ship ] || continue
    plan_issue=$(sed -n 's/^plan_issue=//p' "$meta" | head -n 1)
    [ -n "$plan_issue" ] || continue
    plan_spec=$(sed -n 's/^plan_spec=//p' "$meta" | head -n 1)
    if [ -z "$plan_spec" ]; then
      if ! fm_plan_gate_issue "$plan_issue" --any-state; then
        FM_PLAN_GATE_REASON="$task: $FM_PLAN_GATE_REASON"
        return 1
      fi
      if ! fm_plan_gate_spec; then
        FM_PLAN_GATE_REASON="$task: cannot resolve the spec of $plan_issue"
        return 1
      fi
      plan_spec=$FM_PLAN_GATE_SPEC
    fi
    FM_PLAN_GATE_IN_FLIGHT="$FM_PLAN_GATE_IN_FLIGHT$plan_spec	$task
"
    FM_PLAN_GATE_IN_FLIGHT_COUNT=$((FM_PLAN_GATE_IN_FLIGHT_COUNT + 1))
  done
}
