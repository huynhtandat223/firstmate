#!/usr/bin/env bash
# Move a "verification pending" backlog row to Done from the Tester's own-home record and
# firstmate's approval through fm-verify-gate-lib.sh, without copying the Tester's record.
#
# Usage: fm-verify-close.sh <task-id>
#
# bin/fm-teardown.sh cleans up a landed surface=user-visible ship task whose data/<id>/verify.md
# is incomplete, leaves its backlog row open, and holds that row as external with the reason
# "verification pending: <missing items>". This is the one command that closes such a row:
#   - The row must be open and held with a "verification pending:" reason, and that hold must be
#     external. A Done row, an unheld row, a captain hold or any other hold is refused unchanged.
#   - Complete records (bin/fm-verify-gate-lib.sh owns the check; nothing here parses them)
#     runs `tasks-axi done`, which closes the held row and clears its hold in one mutation. The PR link teardown recorded stays on the row.
#   - An incomplete record is refused: the missing items are printed and the hold reason is
#     refreshed to them, so the row never shows a stale snapshot.
# Exit 0 only when the row moved to Done. Environment: FM_HOME, FM_DATA_OVERRIDE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-verify-gate-lib.sh
. "$SCRIPT_DIR/fm-verify-gate-lib.sh"

PREFIX='verification pending: '

refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] || { echo 'usage: fm-verify-close.sh <task-id>' >&2; exit 2; }
ID=$1
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;; esac

out=$(fm_backlog_row_show "$DATA" "$ID") || refuse "cannot read backlog row $ID: $(printf '%s\n' "$out" | sed -n '1p')"
field() { printf '%s\n' "$out" | sed -n "s/^  $1: *//p" | head -1 | sed 's/^"//; s/"$//'; }
state=$(field state)
held=$(field held)
kind=$(field hold_kind)
reason=$(field hold_reason)
case "$reason" in
  fm-hold-v1:*) reason=$(fm_backlog_verify_items_decode "$reason") || reason= ;;
esac

[ "$state" != "done" ] || refuse "$ID is already Done; nothing was changed."
[ "$held" = yes ] || refuse "$ID is not held for verification; nothing was changed."
[ "$kind" = external ] || refuse "$ID is held as $kind, not as verification pending; nothing was changed."
case "$reason" in
  "$PREFIX"*) ;;
  *) refuse "$ID is held for another reason, not verification pending; nothing was changed." ;;
esac

problems=$(fm_verify_gate_problems "$DATA" "$ID" "$FM_HOME") || true
if [ -n "$problems" ]; then
  fm_backlog_mutate "$DATA" hold "$ID" --reason "$(fm_backlog_verify_reason "$ID" "$problems")" --kind external \
    || echo "warning: the hold reason of $ID could not be refreshed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  printf 'REFUSED: verification records for %s/%s are not complete; %s stays held as verification pending.\n' "$DATA" "$ID" "$ID" >&2
  printf '%s\n' "$problems" | sed 's/^/  - /' >&2
  exit 1
fi

# One mutation: tasks-axi done on a held row closes it and clears the hold, so the row is never
# open and unheld.
if ! fm_backlog_done "$DATA" "$ID"; then
  refuse "could not move $ID to Done ($FM_BACKLOG_TRANSITION_ERROR); it stays held as verification pending."
fi
rm -f -- "$DATA/$ID/verify-pending"
# Opt-in task record shadow (bin/fm-task-shadow.sh); off costs one file test.
[ ! -e "$CONFIG/task-shadow" ] || FM_HOME=$FM_HOME FM_CONFIG_OVERRIDE=$CONFIG FM_DATA_OVERRIDE=$DATA "$SCRIPT_DIR/fm-task-shadow.sh" verified "$ID" || true
echo "Backlog: $ID is Done. Its verification record is complete."
