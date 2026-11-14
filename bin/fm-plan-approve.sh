#!/usr/bin/env bash
# Usage: fm-plan-approve.sh <https://github.com/owner/repo/issues/number> [--note <text>]
# Post approval of the current open issue body and print the comment URL.
# Marker first line: approved: firstmate <UTC epoch> body-sha256:<64 lowercase hex>
# Pull requests, closed issues, and non-GitHub issue URLs are refused.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fm-plan-gate-lib.sh"
if [ "${1:-}" = --help ]; then
  head -n 5 "$0"
  exit 0
fi
[ "$#" -ge 1 ] || { echo 'error: issue URL required' >&2; exit 1; }
url=$1
shift
note=
if [ "$#" -ne 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --note ] || { echo 'error: expected --note <text>' >&2; exit 1; }
  note=$2
fi
if ! fm_plan_gate_issue "$url"; then
  printf 'error: %s\n' "$FM_PLAN_GATE_REASON" >&2
  exit 1
fi
if [ -n "${FM_PLAN_GATE_TASK:-}" ]; then
  fm_plan_gate_task plan-approve "$FM_PLAN_GATE_TASK" --note "$note"
  exit $?
fi
if ! fm_plan_gate_spec; then
  echo 'error: plan gate: cannot resolve the spec of the issue' >&2
  exit 1
fi
fm_plan_gate_one_per_repo "$FM_PLAN_GATE_ISSUE_REPO" "$FM_PLAN_GATE_SPEC" || exit 1
body="approved: firstmate $(date +%s) body-sha256:$FM_PLAN_GATE_HASH"
[ -z "$note" ] || body="$body
$note"
fm_plan_gate_read "$FM_PLAN_GATE_PATH/comments" -X POST -f "body=$body" --jq .html_url
