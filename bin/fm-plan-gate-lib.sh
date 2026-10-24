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
    FM_PLAN_GATE_PATH="repos/$FM_PLAN_GATE_REPO/issues/${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

fm_plan_gate_read() {
  fm_run_timed "${FM_PLAN_GATE_TIMEOUT_SECS:-20}" gh api "$@"
}

fm_plan_gate_issue() {
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
  if [ "$(printf '%s' "$issue" | jq -r .state)" != open ]; then
    FM_PLAN_GATE_VERDICT=closed
    FM_PLAN_GATE_REASON='issue is closed'
    return 1
  fi
  FM_PLAN_GATE_HASH=$(printf '%s' "$issue" | jq -j '.body // ""' | shasum -a 256 | cut -d' ' -f1)
}

fm_plan_gate_check() {
  fm_plan_gate_issue "$1" || return 1
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
