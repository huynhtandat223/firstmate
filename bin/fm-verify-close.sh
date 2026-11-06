#!/usr/bin/env bash
# Reconcile verification handoff for a record: rows task, or move a "verification pending"
# backlog row to Done from the Tester's own-home record and firstmate's approval through
# fm-verify-gate-lib.sh, without copying the Tester's record.
#
# Usage: fm-verify-close.sh [--check] <task-id>
#
# For a record: rows task (data/<id>/verify.md carries "record: rows"):
#   - Before firstmate approves (task state != done), acts as the one handoff after verify:
#     takes the head the user-visible rows passed on from data/deploy-verify/ledger.jsonl
#     (for a page-only task with no PR, the head of its rows ask), writes the deploy event
#     with that head, clears a transient block whose until date has passed and whose rows
#     all pass, then reports approve ready or prints each missing item with its next action.
#     Firstmate's own `bin/fm-task.sh approve <id>` stays a separate step.
#   - With --check, reads the task record and ledger without writing anything, and reports
#     approve ready or prints each missing item with its next action.
#   - After firstmate approves (task state = done), closes an open "verification pending:"
#     backlog row when one exists, or reports the task already approved and complete.
#
# For a legacy verify.md task (without "record: rows"):
#   - The row must be open and held with a "verification pending:" reason, and that hold must be
#     external. A Done row, an unheld row, a captain hold or any other hold is refused unchanged.
#   - Complete records (bin/fm-verify-gate-lib.sh owns the check; nothing here parses them)
#     run `tasks-axi done`, which closes the held row and clears its hold in one mutation. The PR link teardown recorded stays on the row.
#   - An incomplete record is refused: the missing items are printed and the hold reason is
#     refreshed to them (unless --check is set), so the row never shows a stale snapshot.
# Exit 0 when approve is ready (or the row moved to Done). Environment: FM_HOME, FM_DATA_OVERRIDE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-verify-gate-lib.sh
. "$SCRIPT_DIR/fm-verify-gate-lib.sh"

PREFIX='verification pending: '

refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

CHECK=0
ID=
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help)
      echo 'usage: fm-verify-close.sh [--check] <task-id>'
      exit 0
      ;;
    -*)
      echo 'usage: fm-verify-close.sh [--check] <task-id>' >&2
      exit 2
      ;;
    *)
      [ -z "$ID" ] || { echo 'usage: fm-verify-close.sh [--check] <task-id>' >&2; exit 2; }
      ID=$arg
      ;;
  esac
done
[ -n "$ID" ] || { echo 'usage: fm-verify-close.sh [--check] <task-id>' >&2; exit 2; }
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;; esac

VERIFY_FILE="$DATA/$ID/verify.md"

fm_verify_close_rows() {
  local task_writer ledger repo task_json checks_json
  local task_state task_stage block_kind block_reason hold_until pr_url last_seq current_head
  local has_pr_in_repo=0 ledger_heads='' pass_heads='' target_head='' target_touched='none'
  local visible_count open_count as_deployed_json
  local can_unblock_transient=0 can_advance_ready_to_review=0 need_deploy_event=0 need_verify_md_deployed=0
  local until_future=0 after_unblock_state approve_out
  local -a blocking_items=() handoff_items=()

  # shellcheck source=bin/fm-task-shadow-config-lib.sh
  . "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
  fm_task_shadow_config "$CONFIG/task-shadow"
  task_writer=${FM_VERIFY_GATE_TASK:-${FM_TASK_SHADOW_WRITER:-$SCRIPT_DIR/fm-task.sh}}
  ledger="$DATA/deploy-verify/ledger.jsonl"
  repo=${FM_DEPLOY_VERIFY_REPO:-huynhtandat223/cfw-modules}

  task_json=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" show "$ID" --json 2>&1) \
    || refuse "cannot read task record $ID: $(printf '%s\n' "$task_json" | sed -n '1p')"
  checks_json=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" checks "$ID" 2>&1) \
    || refuse "cannot read check rows for $ID: $(printf '%s\n' "$checks_json" | sed -n '1p')"

  task_state=$(jq -r '.state // empty' <<<"$task_json")
  task_stage=$(jq -r '.stage // empty' <<<"$task_json")
  block_kind=$(jq -r '.blockKind // empty' <<<"$task_json")
  block_reason=$(jq -r '.blockReason // empty' <<<"$task_json")
  hold_until=$(jq -r '.holdUntil // empty' <<<"$task_json")
  pr_url=$(jq -r '.prUrl // empty' <<<"$task_json")
  last_seq=$(jq -r '.lastSeq // 0' <<<"$task_json")
  current_head=$(jq -r '.head // empty' <<<"$checks_json")

  if [ "$task_state" = "done" ]; then
    local task_section backlog_closed row_out row_state row_held row_kind row_reason
    task_section=$(jq -r '.section // empty' <<<"$task_json")
    backlog_closed=$(jq -r '.backlogClosed // empty' <<<"$task_json")
    if [ "$task_section" != "Done" ] && [ -z "$backlog_closed" ] && row_out=$(fm_backlog_row_show "$DATA" "$ID" 2>/dev/null); then
      row_state=$(printf '%s\n' "$row_out" | sed -n 's/^  state: *//p' | head -1 | sed 's/^"//; s/"$//')
      row_held=$(printf '%s\n' "$row_out" | sed -n 's/^  held: *//p' | head -1 | sed 's/^"//; s/"$//')
      row_kind=$(printf '%s\n' "$row_out" | sed -n 's/^  hold_kind: *//p' | head -1 | sed 's/^"//; s/"$//')
      row_reason=$(printf '%s\n' "$row_out" | sed -n 's/^  hold_reason: *//p' | head -1 | sed 's/^"//; s/"$//')
      case "$row_reason" in
        fm-hold-v1:*) row_reason=$(fm_backlog_verify_items_decode "$row_reason") || row_reason= ;;
      esac
      if [ "$row_state" != "done" ] && [ "$row_held" = yes ] && [ "$row_kind" = external ] && [[ "$row_reason" == "$PREFIX"* ]]; then
        return 1
      fi
    fi
    printf 'approve ready task=%s state=done%s; next: none\n' "$ID" "${current_head:+ head=$current_head}"
    exit 0
  fi

  if [[ "$pr_url" == "https://github.com/$repo/pull/"[0-9]* ]]; then
    has_pr_in_repo=1
  elif fm_verify_gate_task_in_repo "$STATE" "$DATA" "$ID" "$repo"; then
    has_pr_in_repo=1
  fi

  if [ "$has_pr_in_repo" -eq 1 ]; then
    ledger_heads=$(fm_verify_gate_ledger_shas "$ledger" "$ID")
  else
    # Page-only task with no PR: take the head of its rows ask in the deploy-verify ledger.
    # shellcheck disable=SC2016
    ledger_heads=$(
      [ ! -f "$ledger" ] || jq -Rnr --arg t "$ID" '
        [inputs | fromjson? | select(.type == "ask" and .round == "rows" and .task == $t) | (.head // .sha) | select(type == "string" and length > 0)]
        | reduce .[] as $s ([]; if index([$s]) then . else . + [$s] end) | .[]' "$ledger"
    )
  fi

  visible_count=$(jq '[.rows[] | select(.surface == "user-visible" and .status != "off")] | length' <<<"$checks_json")
  open_count=$(jq '[.rows[] | select((.surface // "") != "checklist" and (.status == "pending" or .status == "fail"))] | length' <<<"$checks_json")
  pass_heads=$(jq -r '[.rows[] | select(.surface == "user-visible" and .status == "pass" and (.head // "") != "") | .head] | unique[]' <<<"$checks_json")

  if [ -n "$ledger_heads" ]; then
    target_head=$(printf '%s\n' "$ledger_heads" | sed -n 1p)
    local h cmp_status
    for h in $(printf '%s\n' "$ledger_heads" | sed 1d); do
      if cmp_status=$("${FM_VERIFY_GATE_GH:-gh}" api "repos/$repo/compare/$target_head...$h" --jq .status 2>/dev/null); then
        case "$cmp_status" in
          ahead) target_head=$h ;;
          behind|identical) ;;
          *) target_head=$h ;;
        esac
      else
        target_head=$h
      fi
    done
  fi

  if [ -n "$target_head" ] && [ -f "$ledger" ]; then
    # shellcheck disable=SC2016
    target_touched=$(
      jq -Rr --arg t "$ID" --arg h "$target_head" '
        fromjson? | select(.type == "ask" and .task == $t and (.sha == $h or .head == $h))
        | if .round == "rows" then "none" elif has("touched") then (.touched // "none") else "all" end
      ' "$ledger" | tail -n 1
    )
    target_touched=${target_touched:-none}
  fi

  if [ "$visible_count" -eq 0 ]; then
    blocking_items+=("$ID has no user-visible check rows in the task record; next: bin/fm-task.sh rows $ID task:$ID --surface user-visible")
  fi

  if [ "$open_count" -gt 0 ]; then
    while IFS=$'\t' read -r r_key r_status r_actor r_head; do
      [ -n "$r_key" ] || continue
      if [ "$r_status" = pending ] && [ "$r_actor" = tester ]; then
        local ask_tester=''
        if [ -n "$r_head" ] && [ -f "$ledger" ]; then
          # shellcheck disable=SC2016
          ask_tester=$(jq -Rr --arg t "$ID" --arg h "$r_head" 'fromjson? | select(.type == "ask" and .task == $t and (.sha == $h or .head == $h)) | (.tester // "sent")' "$ledger" | tail -n 1)
        fi
        if [ -n "$ask_tester" ]; then
          blocking_items+=("$r_key is pending for tester on $r_head ($ask_tester); next: bin/fm-task.sh check $ID $r_key pass|fail --evidence <path|url> --head $r_head")
        else
          blocking_items+=("$r_key is pending for tester${r_head:+ on $r_head} (no verify ask in ledger); next: bin/fm-procevent-deploy-verify.sh ask-rows $ID")
        fi
      elif [ "$r_status" = fail ] || [ "$r_actor" = worker ]; then
        blocking_items+=("$r_key is $r_status for worker${r_head:+ on $r_head}; next: bin/fm-task.sh changes $ID --note \"fix $r_key\"")
      elif [ "$r_actor" = owner ]; then
        blocking_items+=("$r_key is $r_status for owner; next: bin/fm-task.sh check $ID $r_key pass|fail --evidence <note> --role owner")
      else
        blocking_items+=("$r_key is $r_status [${r_actor:-unknown}]; next: bin/fm-task.sh check $ID $r_key pass|fail --evidence <path|url>${r_head:+ --head $r_head}")
      fi
    done < <(jq -r '.rows[] | select((.surface // "") != "checklist" and (.status == "pending" or .status == "fail")) | [.key, .status, (.nextActor // ""), (.head // "")] | @tsv' <<<"$checks_json")
  fi

  if [ -z "$target_head" ]; then
    if [ -n "$pass_heads" ]; then
      blocking_items+=("user-visible rows of $ID passed on $(printf '%s' "$pass_heads" | tr '\n' ',' | sed 's/,$//'), which has no verify ask in $ledger; next: bin/fm-procevent-deploy-verify.sh ask-rows $ID")
    else
      blocking_items+=("no verify ask for $ID in $ledger; next: bin/fm-procevent-deploy-verify.sh ask-rows $ID")
    fi
  elif [ "$visible_count" -gt 0 ] && [ "$open_count" -eq 0 ]; then
    if as_deployed_json=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" checks "$ID" --as-deployed "$target_head" --touched "$target_touched" 2>/dev/null); then
      while IFS=$'\t' read -r r_key r_head; do
        [ -n "$r_key" ] || continue
        blocking_items+=("$r_key passed on ${r_head:-no head}, not ledger head $target_head; next: bin/fm-procevent-deploy-verify.sh ask-rows $ID")
      done < <(jq -r '.rows[] | select(.surface == "user-visible" and .due == true) | [.key, (.head // "")] | @tsv' <<<"$as_deployed_json")
    fi
  fi

  if [ "$task_state" = blocked ]; then
    if [ "$block_kind" = transient ]; then
      if [ -n "$hold_until" ] && ! node -e 'process.exit(Date.parse(process.argv[1]) <= Date.now() ? 0 : 1)' "$hold_until" 2>/dev/null; then
        until_future=1
      fi
      if [ "$until_future" -eq 1 ]; then
        blocking_items+=("transient block on $ID until $hold_until is still active (${block_reason:-waiting}); next: wait until $hold_until or run bin/fm-task.sh unblock $ID")
      elif [ "${#blocking_items[@]}" -eq 0 ]; then
        can_unblock_transient=1
        handoff_items+=("transient block on $ID until ${hold_until:-now} has passed and all check rows pass; next: bin/fm-verify-close.sh $ID")
      else
        blocking_items+=("transient block on $ID until ${hold_until:-now} has passed while check rows are open; next: finish check rows then run bin/fm-verify-close.sh $ID")
      fi
    else
      blocking_items+=("$ID is blocked (${block_kind:-blocked}: ${block_reason:-no reason}); next: bin/fm-task.sh unblock $ID")
    fi
  elif [ "$task_state" != review ]; then
    if [ "$task_state" = ready ] && [ ! -f "$STATE/$ID.meta" ] && [ "${#blocking_items[@]}" -eq 0 ]; then
      can_advance_ready_to_review=1
      handoff_items+=("$ID is in state ready after unblock with all check rows passing; next: bin/fm-verify-close.sh $ID")
    else
      blocking_items+=("$ID is in state $task_state, not review; next: bin/fm-task.sh done $ID --summary <summary> --changed-files <files> --verification <proof> --residual-risk <risk>")
    fi
  fi

  local cl_deploy_open=0
  cl_deploy_open=$(jq '[.rows[] | select(.key == "cl:deploy@-" and (.status == "pending" or .status == "fail"))] | length' <<<"$checks_json")
  while IFS=$'\t' read -r cl_key cl_status; do
    [ -n "$cl_key" ] || continue
    local cl_item=${cl_key#cl:}
    cl_item=${cl_item%@-}
    blocking_items+=("$cl_key is $cl_status; next: satisfy $cl_item or run bin/fm-task.sh checklist $ID off $cl_item --reason <why>")
  done < <(jq -r '.rows[] | select((.surface // "") == "checklist" and .key != "cl:deploy@-" and .key != "cl:tester@-" and (.status == "pending" or .status == "fail")) | [.key, .status] | @tsv' <<<"$checks_json")

  if [ -n "$target_head" ] && { [ "$current_head" != "$target_head" ] || [ "$task_stage" != dev ] || [ "$cl_deploy_open" -gt 0 ] || [ "$can_unblock_transient" -eq 1 ] || [ "$can_advance_ready_to_review" -eq 1 ]; }; then
    need_deploy_event=1
    if [ "${#blocking_items[@]}" -eq 0 ]; then
      handoff_items+=("no deploy event for $ID on head $target_head after its last done; next: bin/fm-verify-close.sh $ID")
    else
      blocking_items+=("no deploy event for $ID on head $target_head after its last done; next: bin/fm-verify-close.sh $ID after check rows pass")
    fi
  fi

  if [ "$has_pr_in_repo" -eq 0 ] && [ -n "$target_head" ] && [ "$(fm_verify_gate_field "$VERIFY_FILE" deployed)" != "$target_head" ]; then
    need_verify_md_deployed=1
    if [ "$need_deploy_event" -eq 0 ] && [ "${#blocking_items[@]}" -eq 0 ]; then
      handoff_items+=("$VERIFY_FILE does not record deployed: $target_head; next: bin/fm-verify-close.sh $ID")
    fi
  fi

  if [ "${#blocking_items[@]}" -gt 0 ]; then
    printf 'REFUSED: verification handoff for %s is not complete:\n' "$ID" >&2
    printf '  - %s\n' "${blocking_items[@]}" >&2
    exit 1
  fi

  if [ "$CHECK" -eq 1 ]; then
    if [ "${#handoff_items[@]}" -gt 0 ]; then
      printf 'REFUSED: verification handoff for %s has pending writes:\n' "$ID" >&2
      printf '  - %s\n' "${handoff_items[@]}" >&2
      exit 1
    fi
    printf 'approve ready task=%s state=review head=%s; next: bin/fm-task.sh approve %s\n' "$ID" "$target_head" "$ID"
    exit 0
  fi

  if [ "$can_unblock_transient" -eq 1 ]; then
    FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" unblock "$ID" \
      --key "verify-close:$ID:unblock:$last_seq" >/dev/null \
      || refuse "could not clear transient block on $ID; next: bin/fm-task.sh unblock $ID"
    after_unblock_state=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" show "$ID" --json 2>/dev/null | jq -r '.state // empty')
    if [ "$after_unblock_state" = ready ] && [ ! -f "$STATE/$ID.meta" ]; then
      can_advance_ready_to_review=1
    fi
  fi

  if [ "$can_advance_ready_to_review" -eq 1 ]; then
    FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" start "$ID" \
      --key "verify-close:$ID:start:$last_seq" >/dev/null \
      || refuse "could not start $ID after unblock; next: bin/fm-task.sh start $ID"
    FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" "done" "$ID" \
      --summary "verify handoff: transient wait cleared and rows passed" \
      --changed-files - \
      --verification "rows passed on $target_head" \
      --residual-risk - \
      --key "verify-close:$ID:done:$last_seq" >/dev/null \
      || refuse "could not move $ID to review after unblock; next: bin/fm-task.sh done $ID --summary <summary> --changed-files - --verification <proof> --residual-risk -"
  fi

  if [ "$need_deploy_event" -eq 1 ]; then
    FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" event "$ID" deploy \
      --head "$target_head" \
      --touched "$target_touched" \
      --note "verify handoff: rows passed on $target_head (bin/fm-verify-close.sh)" \
      --key "verify-close:$ID:deploy:$target_head:$last_seq" >/dev/null \
      || refuse "could not write deploy event for $ID on head $target_head; next: bin/fm-task.sh event $ID deploy --head $target_head --touched $target_touched --note \"verify handoff\""
  fi

  if [ "$need_verify_md_deployed" -eq 1 ] && [ "$(fm_verify_gate_field "$VERIFY_FILE" deployed)" != "$target_head" ]; then
    printf 'deployed: %s\n' "$target_head" >> "$VERIFY_FILE" \
      || refuse "could not append deployed: $target_head to $VERIFY_FILE"
  fi

  if ! approve_out=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA "$task_writer" approve "$ID" --check 2>&1); then
    refuse "$(printf '%s\n' "$approve_out" | sed -n '1p'); next: bin/fm-task.sh approve $ID --check"
  fi

  printf 'approve ready task=%s state=review head=%s; next: bin/fm-task.sh approve %s\n' "$ID" "$target_head" "$ID"
  exit 0
}

if [ -f "$VERIFY_FILE" ] && [ "$(fm_verify_gate_field "$VERIFY_FILE" record)" = rows ]; then
  fm_verify_close_rows
fi

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
  if [ "$CHECK" -eq 0 ]; then
    fm_backlog_mutate "$DATA" hold "$ID" --reason "$(fm_backlog_verify_reason "$ID" "$problems")" --kind external \
      || echo "warning: the hold reason of $ID could not be refreshed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  fi
  printf 'REFUSED: verification records for %s/%s are not complete; %s stays held as verification pending.\n' "$DATA" "$ID" "$ID" >&2
  printf '%s\n' "$problems" | sed 's/^/  - /' >&2
  exit 1
fi

if [ "$CHECK" -eq 1 ]; then
  echo "Backlog: $ID verification record is complete; next: bin/fm-verify-close.sh $ID"
  exit 0
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
