#!/usr/bin/env bash
# fm-task-owner.sh - the Firstmate board's one writer operation (cfw-modules#1678, change 194).
#
# The API Builder script row `fm-task-owner` on Dev 5001 runs this file over SSH for the owner's buttons on the
# board. The row declares `callerArgument: owner`, so --owner is the signed-in user id that the row appends, never
# a page value. Each action runs bin/fm-task.sh, the one writer, with that owner as actor (`owner:<id>`, role
# owner); the writer keeps seq, the transitions and the projection, and this file adds no rule of its own.
#
# Usage: fm-task-owner.sh --action ACTION --task TASK [--option O] [--row ID@W] [--item I --on|--off] [--decision approve|changes] [--plan-seq N] [--note N] [--to RECIPIENT] [--ask why|how|wait-what] [--rule ID --state S ...] [--setup JSON] --owner ID
#   inbox-task|inbox-link|inbox-delete resolve a notification (--task is its id; link needs --option task-id)
#   setup    Approve & start: setup TASK --file <the JSON> --by owner, then a queued TASK moves to its first state   needs --setup
#   comment  a task comment: store the note once per owner, note and minute              needs --note
#   answer   a question:     with --question SEQ, answer TASK --question SEQ --option O [--note N] (one card of a
#            round; the last answer returns the task to its worker); without it, comment "answer: <option>"
#            (and " - <note>"), then unblock                                                 needs --option
#   unblock  a block:        comment "<note>", then unblock                                needs --note
#   pass     an owner row:   check TASK ROW pass --evidence "<note>" (or "owner pass")     needs --row
#   fail     an owner row:   check TASK ROW fail --evidence "<note>"                        needs --row and --note
#   plan     a plan verdict: plan-decision TASK --decision D --plan-seq N [--note N]       needs --decision and --plan-seq
#   rule-add|rule-set|rule-delete  a model rule (Settings > Models): rule add|set|delete [--rule ID] with --state
#            --harness --model --effort --rank --account --hours --scope --enabled --warning and --note; an empty
#            value is left out. --task names the record task fm-model-rules. One key per owner, fields and minute.
#   checklist an item:       checklist TASK off|on ITEM [--reason "<note>"]                  needs --item and --on or --off; --off needs --note
#   hold     a captain hold: fm-captain-hold.sh hold TASK --reason "<note>" (default "Held by the owner on the board.")
#   release  lift the hold:  fm-captain-hold.sh answer TASK --decision-file <the note> --release (default "Released by
#            the owner on the board."); hold and release each tell firstmate through fm-inbox note
#   comment delivers a new event in this call: --to firstmate uses fm-inbox note; a live task uses fm-send.
#   Without --to, the task's live worker is selected, else firstmate. Invalid recipients write nothing.
#   --ask on comment stores the skill name and delivers its invocation and the exact --reply-to command.
#   Replayed comment keys do not deliver again.
#   A pass or fail by role owner also sets the row's owner item (bin/fm-task-lib.mjs, check).
#
# Prints one JSON line for the page: {"ok":true|false,"action","task","writes":[writer lines],"error"?}.
# Exits 0, 2 for a usage refusal (nothing written), or the first refusing writer call's code; a refused comment
# stops before the unblock; a refused setup stops before the move.
# Environment: FM_HOME defaults to this file's home (its parent directory), so the status view lands where the
# watcher reads it. FM_TASK_OWNER_WRITER replaces bin/fm-task.sh and FM_TASK_OWNER_HOLD bin/fm-captain-hold.sh (the tests); the writer's own settings
# (FM_TASK_BASE_URL, FM_TASK_TOKEN_FILE) keep their defaults.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WRITER="${FM_TASK_OWNER_WRITER:-$SCRIPT_DIR/fm-task.sh}"
HOLD="${FM_TASK_OWNER_HOLD:-$SCRIPT_DIR/fm-captain-hold.sh}"

ACTION='' TASK='' OPTION='' ROW='' DECISION='' PLAN_SEQ='' NOTE='' OWNER='' TO='' ASK='' RULE='' ITEM='' SWITCH='' QUESTION='' SETUP=''
declare -A RULE_FIELD=()
RULE_FLAGS='state harness model effort rank account hours scope enabled warning'
WRITES='[]'

reply() {  # <ok> [error]: the one JSON line, then exit with the code in RC
  jq -cn --argjson ok "$1" --arg action "$ACTION" --arg task "$TASK" --argjson writes "$WRITES" --arg error "${2:-}" \
    '{ok: $ok, action: $action, task: $task, writes: $writes} + (if $error == "" then {} else {error: $error} end)'
  exit "$RC"
}
usage() { RC=2; reply false "$1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --on|--off) [ -z "$SWITCH" ] || usage 'give --on or --off once'; SWITCH=${1#--}; shift; continue ;;
  esac
  [ "$#" -ge 2 ] || usage "$1 needs a value"
  case "$1" in
    --setup) SETUP=$2 ;;
    --action) ACTION=$2 ;;
    --task) TASK=$2 ;;
    --option) OPTION=$2 ;;
    --row) ROW=$2 ;;
    --decision) DECISION=$2 ;;
    --plan-seq) PLAN_SEQ=$2 ;;
    --note) NOTE=$2 ;;
    --owner) OWNER=$2 ;;
    --to) TO=$2 ;;
    --ask) ASK=$2 ;;
    --rule) RULE=$2 ;;
    --question) QUESTION=$2 ;;
    --state|--harness|--model|--effort|--rank|--account|--hours|--scope|--enabled|--warning) RULE_FIELD[${1#--}]=$2 ;;
    --item) ITEM=$2 ;;
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
    if run setup "$TASK" --file "$setup_file" --by owner; then
      # a task already under way keeps its state: only a queued task starts its flow here
      if [ "$("$WRITER" show "$TASK" --json 2>/dev/null </dev/null | jq -r '.workflowState // "queued"')" = queued ]; then
        first_state=$(jq -r '(if type == "array" then . else .steps end)[0].state' "$setup_file")
        run move "$TASK" --to "$first_state" || RC=$?
      fi
    else
      RC=$?
    fi
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
  inbox-task|inbox-link|inbox-delete)
    case "$ACTION" in
      inbox-task) run inbox "$TASK" --action task ;;
      inbox-link) [ -n "$OPTION" ] || usage 'inbox-link needs --option task-id'; run inbox "$TASK" --action linked --target "$OPTION" ;;
      inbox-delete) run inbox "$TASK" --action delete ;;
    esac || RC=$?
    ;;
  answer)
    [ -n "$OPTION" ] || usage 'answer needs --option'
    if [ -n "$QUESTION" ]; then
      [[ "$QUESTION" =~ ^[1-9][0-9]*$ ]] || usage 'answer --question must be an event seq'
      note_args=()
      [ -z "$NOTE" ] || note_args=(--note "$NOTE")
      run answer "$TASK" --question "$QUESTION" --option "$OPTION" "${note_args[@]}" --key "owner-answer:$TASK:$QUESTION" || RC=$?
    else
      text="answer: $OPTION${NOTE:+ - $NOTE}"
      run comment "$TASK" --note "$text" && run unblock "$TASK" || RC=$?
    fi
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
  plan)
    case "$DECISION" in approve|changes) ;; *) usage 'plan needs --decision approve|changes' ;; esac
    [[ "$PLAN_SEQ" =~ ^[1-9][0-9]*$ ]] || usage 'plan needs --plan-seq N'
    note_args=()
    [ -z "$NOTE" ] || note_args=(--note "$NOTE")
    decision_key=$(printf '%s\0' "$OWNER" "$TASK" "$PLAN_SEQ" "$DECISION" "$NOTE" | sha256sum)
    decision_key=${decision_key%% *}
    run plan-decision "$TASK" --decision "$DECISION" --plan-seq "$PLAN_SEQ" --key "owner-plan:$decision_key" "${note_args[@]}" || RC=$?
    if [ "$RC" -eq 0 ]; then
      verb=$([ "$DECISION" = approve ] && printf 'approved' || printf 'asked for changes to')
      body="The owner $verb the plan of task $TASK (plan seq $PLAN_SEQ)${NOTE:+: $NOTE}"
      [ -n "$NOTE" ] || body="${body}."
      words="${NOTE:-$([ "$DECISION" = approve ] && printf 'Approved on the board.' || printf 'Asked for changes on the board.')}"
      decision_seq=$(jq -r '.[0]' <<<"$WRITES")
      decision_seq=${decision_seq#seq=}; decision_seq=${decision_seq%% *}
      "${FM_TASK_OWNER_INBOX:-$SCRIPT_DIR/fm-inbox.sh}" note --request-id "owner-plan-$TASK-$decision_seq" -- "$body" >/dev/null || { RC=$?; ERROR='plan decision stored but firstmate delivery failed'; }
      if [ "$RC" -eq 0 ] && [ -f "$FM_HOME/data/assistances.md" ] && grep -Eq '^- planner\b' "$FM_HOME/data/assistances.md"; then
        steer_flag="--$(printf '\143\141\160\164\141\151\156')-words"
        "${FM_TASK_OWNER_ASSISTANCE:-$SCRIPT_DIR/fm-assistance.sh}" steer planner "$steer_flag" "$words" "$body" >/dev/null || { RC=$?; ERROR='plan decision stored but planner delivery failed'; }
      fi
    fi
    ;;
  rule-add|rule-set|rule-delete)
    [ "$TASK" = fm-model-rules ] || usage 'a rule action needs --task fm-model-rules'
    verb=${ACTION#rule-}
    if [ "$verb" = add ]; then [ -z "$RULE" ] || usage 'rule-add takes no --rule'; else [ -n "$RULE" ] || usage "$ACTION needs --rule ID"; fi
    rule_args=()
    [ -z "$RULE" ] || rule_args+=("$RULE")
    if [ "$verb" != delete ]; then
      for name in $RULE_FLAGS; do
        [ -z "${RULE_FIELD[$name]:-}" ] || rule_args+=("--$name" "${RULE_FIELD[$name]}")
      done
      [ -z "$NOTE" ] || rule_args+=(--note "$NOTE")
    fi
    digest=$(printf '%s\0' "$OWNER" "$ACTION" "${rule_args[@]}" "$(date -u +%Y-%m-%dT%H:%M)" | sha256sum) || usage 'rule digest failed'
    run rule "$verb" "${rule_args[@]}" --key "owner-rule:${digest%% *}" || RC=$?
    ;;
  checklist)
    [ -n "$ITEM" ] || usage 'checklist needs --item'
    case "$SWITCH" in
      off) [[ "$NOTE" =~ [^[:space:]] ]] || usage 'checklist --off needs a nonblank --note'; run checklist "$TASK" off "$ITEM" --reason "$NOTE" || RC=$? ;;
      on) if [ -n "$NOTE" ]; then run checklist "$TASK" on "$ITEM" --reason "$NOTE" || RC=$?; else run checklist "$TASK" on "$ITEM" || RC=$?; fi ;;
      *) usage 'checklist needs --on or --off' ;;
    esac
    ;;
  hold|release)
    WRITER=$HOLD
    if [ "$ACTION" = hold ]; then
      words=${NOTE:-Held by the owner on the board.}
      run hold "$TASK" --reason "$words" || RC=$?
    else
      words=${NOTE:-Released by the owner on the board.}
      decision_file=$(mktemp "${TMPDIR:-/tmp}/fm-owner-release.XXXXXX") || usage 'no temporary file'
      trap 'rm -f "$decision_file"' EXIT
      printf '%s\n' "$words" > "$decision_file"
      run answer "$TASK" --decision-file "$decision_file" --release || RC=$?
    fi
    if [ "$RC" -eq 0 ]; then
      verb=$([ "$ACTION" = hold ] && printf 'held' || printf 'released the hold on')
      "${FM_TASK_OWNER_INBOX:-$SCRIPT_DIR/fm-inbox.sh}" note --request-id "owner-$ACTION-$TASK-$(date -u +%Y%m%dT%H%M%S)" -- "The owner $verb task $TASK on the board: $words" >/dev/null || { RC=$?; ERROR="$ACTION stored but firstmate delivery failed"; }
    fi
    ;;
  *) usage "--action must be setup, comment, answer, unblock, pass, fail, plan, checklist, hold, release, rule-add, rule-set, rule-delete, inbox-task, inbox-link or inbox-delete" ;;
esac
if [ "$RC" -eq 0 ]; then reply true; else reply false "$ERROR"; fi
