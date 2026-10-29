#!/usr/bin/env bash
# Task identity checks (spec huynhtandat223/firstmate#200, E7). Three mistakes:
# a done task id reused, a second task for one ticket key, and a task linked to
# a PR that closes another issue.
#
# Usage: fm-task-identity-check.sh add <id> <title> [<repo>]
#        fm-task-identity-check.sh pr <id> <pr-url>
#
# add: called by bin/fm-tasks-axi.sh add|create before tasks-axi runs and by
#   bin/fm-task.sh create. It refuses
#   - an id found as a done row in data/done-archive.md or data/backlog.md,
#     citing the file and line;
#   - an id with a local fm/<id> branch in the project clone <repo> (the pool
#     worktrees share that clone's refs), naming the branch; only when <repo> is
#     given, which intake does and the create that follows dispatch does not;
#   - a title that carries a ticket key (DEV-n, PS-n) already carried by the
#     title of a live (unchecked) backlog task, naming that task.
# pr: called by bin/fm-pr-check.sh. The task's linked issue is the first
#   .../issues/<n> URL in its backlog item. It refuses a GitHub PR whose closing
#   references name other issues and omit that one, naming both. A PR with no
#   closing reference, an item with no linked issue, or an unreadable forge
#   passes: nothing can be compared.
# Log-only until config/enforce-task-identity holds `block` (bin/fm-enforce-lib.sh);
# until then each hit is written to state/enforce-task-identity.log and the
# command goes on. A refusal prints the fix and exits 1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-enforce-lib.sh
. "$SCRIPT_DIR/fm-enforce-lib.sh"

# hit <code> <text>: log, and refuse when the switch holds block.
hit() {
  if [ "$(fm_enforce_mode "$CONFIG" task-identity)" != block ]; then
    fm_enforce_log "$STATE" task-identity would-refuse "$1" "$2"
    exit 0
  fi
  fm_enforce_log "$STATE" task-identity refuse "$1" "$2"
  echo "error: task identity: $2" >&2
  exit 1
}

check_add() {
  local id=$1 title=$2 repo=${3:-} file line key other clone
  for file in "$DATA/done-archive.md" "$DATA/backlog.md"; do
    [ -f "$file" ] || continue
    line=$(awk -v id="$id" '$1 == "-" && $2 == "[x]" && $3 == id { print NR; exit }' "$file")
    [ -z "$line" ] || hit reused-id "task id $id is already a done task (data/$(basename "$file"):$line); use a new id, or reopen that task if it is the same work"
  done
  if [ -n "$repo" ]; then
    clone="$PROJECTS/$repo"
    if [ -d "$clone" ] && [ -n "$(git -C "$clone" for-each-ref --format='%(refname)' "refs/heads/fm/$id" 2>/dev/null)" ]; then
      hit reused-branch "task id $id already has the branch fm/$id in projects/$repo; use a new id"
    fi
  fi
  [ -f "$DATA/backlog.md" ] || return 0
  for key in $(printf '%s' "$title" | grep -oiE '\b(DEV|PS)-[0-9]+\b' | tr '[:lower:]' '[:upper:]' | sort -u); do
    other=$(awk -v id="$id" -v key="$key" '
      /^- \[ \] [^ ]+ - / {
        row = $0; sub(/^- \[ \] /, "", row); rid = row; sub(/ .*/, "", rid)
        title = row; sub(/^[^ ]+ - /, "", title)
        if (rid != id && match(toupper(title), "(^|[^A-Z0-9])" key "([^0-9]|$)")) { print rid; exit }
      }' "$DATA/backlog.md")
    [ -z "$other" ] || hit duplicate-key "ticket $key is already carried by the live task $other; continue that task, or finish it before adding $id"
  done
}

check_pr() {
  local id=$1 url=$2 block linked closes ref
  [ -f "$DATA/backlog.md" ] || exit 0
  block=$(awk -v id="$id" '
    /^- \[[ x]\] / { row = $0; sub(/^- \[[ x]\] /, "", row); sub(/ .*/, "", row); on = (row == id) }
    on { print }' "$DATA/backlog.md")
  linked=$(printf '%s\n' "$block" | grep -oE 'https?://[^ )]+/issues/[0-9]+' | head -1)
  [ -n "$linked" ] || exit 0
  case "$url" in https://github.com/*/pull/*) ;; *) exit 0 ;; esac
  command -v gh >/dev/null 2>&1 || exit 0
  closes=$(gh pr view "$url" --json closingIssuesReferences --jq '.closingIssuesReferences[].url' 2>/dev/null) || exit 0
  [ -n "$closes" ] || exit 0
  while IFS= read -r ref; do
    [ "$ref" != "$linked" ] || exit 0
  done <<< "$closes"
  hit wrong-issue "PR $url closes $(printf '%s' "$closes" | tr '\n' ' ')but task $id is linked to $linked; link the PR that closes $linked, or correct the task's issue"
}

case "${1:-}" in
  add) [ "$#" -ge 3 ] || { echo "usage: fm-task-identity-check.sh add <id> <title> [<repo>]" >&2; exit 2; }; check_add "$2" "$3" "${4:-}" ;;
  pr) [ "$#" -eq 3 ] || { echo "usage: fm-task-identity-check.sh pr <id> <pr-url>" >&2; exit 2; }; check_pr "$2" "$3" ;;
  *) echo "usage: fm-task-identity-check.sh add <id> <title> [<repo>] | pr <id> <pr-url>" >&2; exit 2 ;;
esac
exit 0
