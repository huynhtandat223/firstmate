#!/usr/bin/env bash
# fm-task-owner.sh - the Firstmate board's one writer operation (cfw-modules#1678, change 194).
#
# The API Builder script row `fm-task-owner` on Dev 5001 runs this file over SSH for the owner's buttons on the
# board. The row declares `callerArgument: owner`, so --owner is the signed-in user id that the row appends, never
# a page value. Each action runs bin/fm-task.sh, the one writer, with that owner as actor (`owner:<id>`, role
# owner); the writer keeps seq, the transitions and the projection, and this file adds no rule of its own.
#
# Usage: fm-task-owner.sh --action ACTION --task TASK [--option O] [--row ID@W] [--note N] [--to RECIPIENT] [--ask why|how|wait-what] --owner ID
#   comment  a task comment: store the note once per owner, note and minute              needs --note
#   answer   a question:     comment "answer: <option>" (and " - <note>"), then unblock    needs --option
#   unblock  a block:        comment "<note>", then unblock                                needs --note
#   pass     an owner row:   check TASK ROW pass --evidence "<note>" (or "owner pass")     needs --row
#   fail     an owner row:   check TASK ROW fail --evidence "<note>"                        needs --row and --note
#   comment delivers a new event in this call: --to firstmate uses fm-inbox note; a live task uses fm-send.
#   Without --to, the task's live worker is selected, else firstmate. Invalid recipients write nothing.
#   --ask on comment stores the skill name and delivers its invocation and the exact --reply-to command.
#   Replayed comment keys do not deliver again.
#   A pass or fail by role owner also sets the row's owner item (bin/fm-task-lib.mjs, check).
#
# Prints one JSON line for the page: {"ok":true|false,"action","task","writes":[writer lines],"error"?}.
# Exits 0, 2 for a usage refusal (nothing written), or the first refusing writer call's code; a refused comment
# stops before the unblock.
# Environment: FM_HOME defaults to this file's home (its parent directory), so the status view lands where the
# watcher reads it. FM_TASK_OWNER_WRITER replaces bin/fm-task.sh (the tests); the writer's own settings
# (FM_TASK_BASE_URL, FM_TASK_TOKEN_FILE) keep their defaults.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WRITER="${FM_TASK_OWNER_WRITER:-$SCRIPT_DIR/fm-task.sh}"

ACTION='' TASK='' OPTION='' ROW='' NOTE='' OWNER='' TO='' ASK='' SETUP=''
WRITES='[]'

reply() {  # <ok> [error]: the one JSON line, then exit with the code in RC
  jq -cn --argjson ok "$1" --arg action "$ACTION" --arg task "$TASK" --argjson writes "$WRITES" --arg error "${2:-}" \
    '{ok: $ok, action: $action, task: $task, writes: $writes} + (if $error == "" then {} else {error: $error} end)'
  exit "$RC"
}
usage() { RC=2; reply false "$1"; }

while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --setup) SETUP=$2 ;;
    --action) ACTION=$2 ;;
    --task) TASK=$2 ;;
    --option) OPTION=$2 ;;
    --row) ROW=$2 ;;
    --note) NOTE=$2 ;;
    --owner) OWNER=$2 ;;
    --to) TO=$2 ;;
    --ask) ASK=$2 ;;
    *) usage "unknown argument $1" ;;
  esac
  shift 2
done

case "$OWNER" in ''|*[!A-Za-z0-9-]*) usage 'no signed-in owner: the script row must append --owner' ;; esac
[ "${#OWNER}" -le 56 ] || usage 'the owner id is longer than 56 characters'
[ -n "$TASK" ] || usage '--task is required'
if [ -n "$ASK" ]; then
  [ "$ACTION" = comment ] || usage '--ask is only allowed for comment'
  case "$ASK" in why|how|wait-what) ;; *) usage '--ask must be why, how or wait-what' ;; esac
fi
export FM_TASK_ACTOR="owner:$OWNER" FM_TASK_ROLE=owner
unset FM_TASK_ID

# Run one writer call; its stdout lines join WRITES. Returns the writer's code, with its first error line in ERROR.
ERROR=''
run() {
  local out err rc
  err=$(mktemp "${TMPDIR:-/tmp}/fm-task-owner.XXXXXX") || { ERROR='no temporary file'; return 3; }
  out=$("$WRITER" "$@" 2>"$err" </dev/null)
  rc=$?
  ERROR=$(sed -n '1p' "$err")
  rm -f "$err"
  WRITES=$(jq -c --arg o "$out" '. + ($o | split("\n") | map(select(. != "")))' <<<"$WRITES")
  return "$rc"
}

# Resolve only recorded workers in this home, using the shared backend liveness interface.
worker_live() {
  local meta="$FM_HOME/state/$1.meta" backend target
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [ -f "$meta" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ "$(fm_backend_agent_alive "$backend" "$target")" = alive ]
}

RC=0
case "$ACTION" in
  setup)
    [ -n "$SETUP" ] || usage 'setup needs --setup JSON'
    setup_file=$(mktemp "${TMPDIR:-/tmp}/fm-owner-setup.XXXXXX") || usage 'no temporary file'
    trap 'rm -f "$setup_file"' EXIT
    printf '%s' "$SETUP" > "$setup_file"
    run setup "$TASK" --file "$setup_file" --by owner || RC=$?
    ;;
  comment)
    [[ "$NOTE" =~ [^[:space:]] ]] || usage 'comment needs a nonblank --note'
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    if [ -z "$TO" ]; then
      if worker_live "$TASK"; then TO=$TASK; else TO=firstmate; fi
    fi
    [ "$TO" = firstmate ] || worker_live "$TO" || usage 'recipient must be firstmate or a live worker'
    if [ -z "$ASK" ]; then
      digest=$(printf '%s\0%s\0%s' "$OWNER" "$NOTE" "$(date -u +%Y-%m-%dT%H:%M)" | sha256sum) || usage 'comment digest failed'
    else
      digest=$(printf '%s\0%s\0%s\0%s' "$OWNER" "$NOTE" "$ASK" "$(date -u +%Y-%m-%dT%H:%M)" | sha256sum) || usage 'comment digest failed'
    fi
    digest=${digest%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || usage 'comment digest is empty or invalid'
    ask_args=()
    [ -z "$ASK" ] || ask_args=(--ask "$ASK")
    run comment "$TASK" --note "$NOTE" "${ask_args[@]}" --key "owner-comment:$TASK:$digest" || RC=$?
    if [ "$RC" -eq 0 ] && ! [[ "$WRITES" == *'(already recorded)'* ]]; then
      seq=$(jq -r '.[0]' <<<"$WRITES")
      seq=${seq#seq=}; seq=${seq%% *}
      [[ "$seq" =~ ^[0-9]+$ ]] || { ERROR='writer returned no comment sequence'; RC=3; }
      if [ "$RC" -eq 0 ]; then
        message="Owner comment on $TASK (seq $seq): $NOTE"
        if [ -n "$ASK" ]; then
          message+=$'\n'"Run the $ASK skill on task $TASK. Reply with: bin/fm-task.sh comment $TASK --reply-to $seq --note <output>"
        fi
        if [ "$TO" = firstmate ]; then
          "$SCRIPT_DIR/fm-inbox.sh" note --request-id "owner-comment-$seq" -- "$message" >/dev/null || { RC=$?; ERROR='comment stored but firstmate delivery failed'; }
        else
          "$SCRIPT_DIR/fm-send.sh" "$TO" "$message" >/dev/null || { RC=$?; ERROR='comment stored but worker delivery failed'; }
        fi
      fi
    fi
    ;;
  answer)
    [ -n "$OPTION" ] || usage 'answer needs --option'
    text="answer: $OPTION${NOTE:+ - $NOTE}"
    run comment "$TASK" --note "$text" && run unblock "$TASK" || RC=$?
    ;;
  unblock)
    [ -n "$NOTE" ] || usage 'unblock needs --note'
    run comment "$TASK" --note "$NOTE" && run unblock "$TASK" || RC=$?
    ;;
  pass|fail)
    [ -n "$ROW" ] || usage "$ACTION needs --row ID@WIDTH"
    [ "$ACTION" = pass ] || [ -n "$NOTE" ] || usage 'fail needs --note'
    run check "$TASK" "$ROW" "$ACTION" --evidence "${NOTE:-owner pass}" || RC=$?
    ;;
  *) usage "--action must be setup, comment, answer, unblock, pass or fail" ;;
esac
if [ "$RC" -eq 0 ]; then reply true; else reply false "$ERROR"; fi
