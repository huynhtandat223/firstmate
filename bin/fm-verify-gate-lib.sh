#!/usr/bin/env bash
# Single owner of the user-visible done gate: the two records a ship task recorded with
# surface=user-visible (bin/fm-spawn.sh --surface) needs before its backlog row moves to Done.
# bin/fm-teardown.sh cleans such a task up either way: with an incomplete gate it
# leaves the row open and held as external ("verification pending: <missing items>"),
# and bin/fm-verify-close.sh moves the row to Done once the gate passes.
# Sourced by both. The wording a worker reads lives in bin/fm-dod-lib.sh.
#
# The acceptance is the issue's scenarios, read by bin/fm-acceptance.mjs. The gate reads
# two records and writes neither:
#   firstmate's  <data-dir>/<task-id>/verify.md
#     surface: user-visible        (line 1; bin/fm-spawn.sh writes it with the next line)
#     issue: <url>
#     deployed: <sha>              (only for a repo deploy-verify does not watch)
#     approved: firstmate <epoch>
#   the Tester's  <tester-home>/data/verify/<task-id>.md
#     surface: user-visible
#     issue: <url>
#     ## Scenarios
#     - <id>@<width> | <line> | pass | evidence: <existing file path or http(s) URL>
#     verified: tester <epoch> head=<sha> acceptance=<digest>
#                                     (after the last row; it covers the rows above it)
# A task begun after T5 (spec huynhtandat223/cfw-modules#1675) carries 'record: rows' in firstmate's record
# (bin/fm-spawn.sh writes it while config/task-shadow is on). For such a task the task record replaces the Tester's
# file and the approved: line: `bin/fm-task.sh gate <task> --issue <url> --head <deployed sha>` must answer clean,
# that is every user-visible row of the issue `pass` with evidence on the deployed head and the scenario's current
# digest, or carried from an earlier deployed head that no later PR names (printed on stderr with that head), and an
# approved event newer than the last row (bin/fm-task-lib.mjs owns that read). Line 1, the issue line
# and the deployed head below are checked as for any task; the writer runs with the settings of config/task-shadow.
# FM_VERIFY_GATE_TASK replaces bin/fm-task.sh (the tests use a stand-in).
# The Tester home is home= in <state>/tester.meta, or FM_TESTER_HOME. A relative evidence
# path resolves against that home. A row in state `retired` is allowed only for a scenario id
# the issue no longer has (not for one width of an id it still has); a row for an issue scenario that is not user-visible is ignored.
# fm_verify_gate_problems <data-dir> <task-id> <base-dir> prints one problem per line on
# stdout and returns 1 when there is any; it prints nothing and returns 0 when
#   - the issue both records name parses, and every row of
#     `fm-acceptance.mjs rows <issue>` is in the Tester record with the issue's current line
#     text, `pass`, and existing evidence,
#   - no Tester row names an id outside the issue,
#   - the Tester's acceptance= equals `fm-acceptance.mjs digest <issue>`: the digest of the full
#     scenarios as they read now, so a scenario edited in any field after the Tester read it
#     is verified again,
#   - the Tester's head= equals the sha of the newest deploy-round or replay ask for the task
#     in <data-dir>/deploy-verify/ledger.jsonl (a missing ask refuses), or, for a task whose PR is
#     not in the repo deploy-verify watches, the 'deployed: <sha>' line of firstmate's record, and
#   - 'approved: firstmate' is newer than the Tester's verified epoch.
# <base-dir> is the firstmate home: <base-dir>/state is the state directory
# (FM_STATE_OVERRIDE overrides it). The check never generates or changes evidence.

FM_VERIFY_GATE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The sha of the newest ask the deploy-verify ledger holds for a task: a deploy round or a
# replay (both are round=deploy), never a draft round. Prints nothing when there is none.
fm_verify_gate_ledger_sha() {  # <ledger> <task-id>
  [ -f "$1" ] || return 0
  # shellcheck disable=SC2016 # jq variables, not shell
  jq -Rr --arg t "$2" 'fromjson? | select(.type == "ask" and .round == "deploy" and .task == $t) | .sha' "$1" | tail -n 1
}

# A record's value for `<key>: ` (the last such line).
fm_verify_gate_field() {  # <file> <key>
  sed -n "s/^$2: //p" "$1" | tail -n 1
}

# Whether the task has a PR in <repo>, read the way bin/fm-procevent-deploy-verify.sh build_map
# maps a task: the endpoint record's pr=, else a PR URL on the task's own backlog line.
fm_verify_gate_task_in_repo() {  # <state-dir> <data-dir> <task-id> <repo>
  local pr
  pr=$(sed -n 's/^pr=//p' "$1/$3.meta" 2>/dev/null | head -n 1)
  case "$pr" in "https://github.com/$4/pull/"[0-9]*) return 0 ;; esac
  [ -f "$2/backlog.md" ] || return 1
  awk -v repo="$4" -v task="$3" '
    /^- \[.\] / && /\(kind: ship\)/ {
      line = $0; sub(/^- \[.\] /, "", line); t = line; sub(/ .*/, "", t)
      if (t == task && match($0, "https://github.com/" repo "/pull/[0-9]+")) found = 1
    }
    END { exit !found }' "$2/backlog.md"
}

# Prints one problem and marks the running fm_verify_gate_problems (its local $bad) as failed.
fm_verify_gate_say() {
  printf '%s\n' "$*"
  bad=1
}

# One evidence value: says the problem for row <rid> when it is not an existing path or URL.
fm_verify_gate_evidence_problem() {  # <rid> <evidence> <base-dir>
  case "$2" in
    http://?*|https://?*) ;;
    ''|-) fm_verify_gate_say "$1 is pass without evidence" ;;
    /*) [ -e "$2" ] || fm_verify_gate_say "$1 evidence path does not exist: $2" ;;
    *) [ -e "$3/$2" ] || fm_verify_gate_say "$1 evidence path does not exist: $2" ;;
  esac
}

# The scenario line of a record row `- <id>@<width> | <line> | <state> | evidence: <x>`, trimmed.
fm_verify_gate_row_text() {  # <row>
  local t=${1#- }
  t=${t#* | }
  t=${t% | *}
  t=${t% | *}
  t=${t#"${t%%[![:space:]]*}"}
  t=${t%"${t##*[![:space:]]}"}
  printf '%s' "$t"
}

# The deployed head, into the running fm_verify_gate_problems' $want_sha (a problem when there is none). deploy-verify
# maps a task by its PR, so a task whose PR is in the repo it watches (FM_DEPLOY_VERIFY_REPO) has the newest ask of the
# task in the ledger as its head, and a missing ask is a refusal; a task with a PR elsewhere has no ask, so it is
# firstmate's own deployed: line. The issue's repo plays no part.
fm_verify_gate_deployed_head() {
  local repo
  repo=${FM_DEPLOY_VERIFY_REPO:-huynhtandat223/cfw-modules}
  if fm_verify_gate_task_in_repo "$state" "$data" "$id" "$repo"; then
    want_sha=$(fm_verify_gate_ledger_sha "$ledger" "$id")
    [ -n "$want_sha" ] || fm_verify_gate_say "no deploy ask for $id in $ledger; its PR is in $repo, which deploy-verify watches, so a deployed: line does not stand in for it"
  else
    want_sha=$(fm_verify_gate_field "$file" deployed)
    [ -n "$want_sha" ] || fm_verify_gate_say "no deployed head for $id: its PR is not in $repo, the repo deploy-verify watches, so $file needs a 'deployed: <sha>' line"
  fi
}

# The rows path for a task begun after T5: firstmate's line 1 and issue line, the deployed head, then the task record's
# own read. Each reason the record gives is one problem; a record that cannot be read is one problem naming why.
fm_verify_gate_rows() {
  local first issue want_sha out err rc config
  first=$(sed -n '1p' "$file")
  [ "$first" = 'surface: user-visible' ] || fm_verify_gate_say "line 1 of $file must be 'surface: user-visible' (found '$first')"
  issue=$(fm_verify_gate_field "$file" issue)
  [ -n "$issue" ] || fm_verify_gate_say "firstmate record has no 'issue: <url>' line"
  fm_verify_gate_deployed_head
  [ -n "$issue" ] && [ -n "$want_sha" ] || return 0
  config=${FM_CONFIG_OVERRIDE:-$base/config}
  err=$(mktemp "${TMPDIR:-/tmp}/fm-verify-gate.XXXXXX") || { fm_verify_gate_say "the task record cannot be read: no temporary file"; return 0; }
  rc=0
  out=$(
    # shellcheck source=bin/fm-task-shadow-config-lib.sh
    . "$FM_VERIFY_GATE_DIR/fm-task-shadow-config-lib.sh"
    fm_task_shadow_config "$config/task-shadow"
    "${FM_VERIFY_GATE_TASK:-$FM_VERIFY_GATE_DIR/fm-task.sh}" gate "$id" --issue "$issue" --head "$want_sha" ${tester_home:+--evidence-root "$tester_home"} 2>"$err" </dev/null
  ) || rc=$?
  # a carried pass (a pass on an earlier deployed head that no later PR names) is no problem: it goes to stderr with its head
  printf '%s\n' "$out" | grep ' carried: pass on head ' >&2 || :
  out=$(printf '%s\n' "$out" | grep -v ' carried: pass on head ' || :)
  if [ "$rc" -eq 5 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    bad=1
  elif [ "$rc" -ne 0 ]; then
    fm_verify_gate_say "the task record cannot be read: $(sed -n '1p' "$err")"
  fi
  rm -f "$err"
}

fm_verify_gate_problems() {  # <data-dir> <task-id> <base-dir>
  local data=$1 id=$2 base=$3 file state tester_home tfile ledger first
  local issue t_issue t_surface approved verified v_epoch v_head want_sha repo
  local rows all_rows parse rc word v_acc cur_acc line rid rstate revidence ev want_text in_scn=0 ln=0 last_row_ln=0 verified_ln
  local bad=0 expected=$'\n' known=$'\n' known_ids=$'\n' seen=$'\n'
  state=${FM_STATE_OVERRIDE:-$base/state}
  file="$data/$id/verify.md"
  ledger="$data/deploy-verify/ledger.jsonl"
  tester_home=${FM_TESTER_HOME:-}
  if [ -z "$tester_home" ] && [ -f "$state/tester.meta" ]; then
    tester_home=$(sed -n 's/^home=//p' "$state/tester.meta" | tail -n 1)
  fi
  tfile="$tester_home/data/verify/$id.md"

  [ -f "$file" ] || fm_verify_gate_say "firstmate verification record missing: $file"
  if [ "$bad" -eq 0 ] && [ "$(fm_verify_gate_field "$file" record)" = rows ]; then
    fm_verify_gate_rows
    return "$bad"
  fi
  if [ -z "$tester_home" ]; then
    fm_verify_gate_say "Tester record missing: no Tester home (no home= in $state/tester.meta and FM_TESTER_HOME is unset)"
  elif [ ! -f "$tfile" ]; then
    fm_verify_gate_say "Tester record missing: $tfile"
  fi
  [ "$bad" -eq 0 ] || return 1

  first=$(sed -n '1p' "$file")
  [ "$first" = 'surface: user-visible' ] || fm_verify_gate_say "line 1 of $file must be 'surface: user-visible' (found '$first')"
  issue=$(fm_verify_gate_field "$file" issue)
  [ -n "$issue" ] || fm_verify_gate_say "firstmate record has no 'issue: <url>' line"
  t_surface=$(fm_verify_gate_field "$tfile" surface)
  [ "$t_surface" = user-visible ] || fm_verify_gate_say "Tester record needs 'surface: user-visible' (found '${t_surface:-none}')"
  t_issue=$(fm_verify_gate_field "$tfile" issue)
  if [ -z "$t_issue" ]; then
    fm_verify_gate_say "Tester record has no 'issue: <url>' line"
  elif [ -n "$issue" ] && [ "$t_issue" != "$issue" ]; then
    fm_verify_gate_say "the records name different issues: firstmate $issue, Tester $t_issue"
  fi

  # The tester line: its epoch is the time the Tester finished; its head is the deployed head
  # it checked.
  verified=$(sed -n 's/^verified: tester //p' "$tfile" | tail -n 1)
  v_epoch=${verified%% *}
  v_head=
  v_acc=
  for word in $verified; do
    case "$word" in
      head=*) v_head=${word#head=} ;;
      acceptance=*) v_acc=${word#acceptance=} ;;
    esac
  done
  case "$v_epoch" in
    ''|*[!0-9]*) fm_verify_gate_say "Tester record has no 'verified: tester <epoch> head=<sha> acceptance=<digest>' line"; v_epoch= ;;
  esac
  if [ -n "$v_epoch" ] && [ -z "$v_head" ]; then
    fm_verify_gate_say "Tester verified line has no head=<sha>: verified: tester $verified"
  fi
  if [ -n "$v_epoch" ] && [ -z "$v_acc" ]; then
    fm_verify_gate_say "Tester verified line has no acceptance=<digest>: verified: tester $verified"
  fi

  fm_verify_gate_deployed_head
  if [ -n "$want_sha" ] && [ -n "$v_head" ] && [ "$v_head" != "$want_sha" ]; then
    fm_verify_gate_say "Tester head $v_head is not the deployed head $want_sha"
  fi

  approved=$(sed -n 's/^approved: firstmate //p' "$file" | tail -n 1)
  case "$approved" in
    '') fm_verify_gate_say "missing 'approved: firstmate <epoch>' line" ;;
    *[!0-9]*) fm_verify_gate_say "approved line needs a numeric epoch: approved: firstmate $approved" ;;
    *)
      if [ -n "$v_epoch" ] && [ "$approved" -le "$v_epoch" ]; then
        fm_verify_gate_say "approved: firstmate $approved is not newer than the Tester's verified epoch $v_epoch"
      fi ;;
  esac

  # The issue's rows are the acceptance.
  if [ -n "$issue" ]; then
    if ! command -v node >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      fm_verify_gate_say "node and jq are required to read $issue"
      return 1
    fi
    rc=0
    rows=$(node "$FM_VERIFY_GATE_DIR/fm-acceptance.mjs" rows "$issue" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      parse=$(node "$FM_VERIFY_GATE_DIR/fm-acceptance.mjs" parse "$issue" 2>&1) || true
      if printf '%s' "$parse" | jq -e '.problems | length > 0' >/dev/null 2>&1; then
        printf '%s' "$parse" | jq -r --arg i "$issue" '.problems[] | "issue \($i) cannot be read: \(.)"'
      else
        fm_verify_gate_say "issue $issue cannot be read: $(printf '%s' "$parse" | sed -n '1p')"
      fi
      return 1
    fi
    [ -n "$rows" ] || fm_verify_gate_say "issue $issue has no user-visible scenario row"
    cur_acc=$(node "$FM_VERIFY_GATE_DIR/fm-acceptance.mjs" digest "$issue" 2>/dev/null) || cur_acc=
    if [ -n "$v_acc" ] && [ "$v_acc" != "$cur_acc" ]; then
      fm_verify_gate_say "Tester acceptance $v_acc is not the issue's current digest $cur_acc"
    fi
    all_rows=$(node "$FM_VERIFY_GATE_DIR/fm-acceptance.mjs" rows "$issue" --surface all 2>/dev/null) || all_rows=$rows
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      expected="$expected$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $1}')"$'\n'
    done <<<"$rows"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rid=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $1}')
      known="$known$rid"$'\n'
      known_ids="$known_ids${rid%%@*}"$'\n'
    done <<<"$all_rows"

    # Every Tester row: a known id is checked for pass and evidence; an unknown id is refused
    # unless the Tester retired it.
    while IFS= read -r line || [ -n "$line" ]; do
      ln=$((ln + 1))
      case "$line" in
        '## Scenarios') in_scn=1; continue ;;
        '#'*) in_scn=0; continue ;;
      esac
      if [ "$in_scn" -eq 0 ]; then
        case "$line" in
          '- '*[!\ ]@*' | '*) fm_verify_gate_say "scenario row outside '## Scenarios': $line" ;;
        esac
        continue
      fi
      case "$line" in '- '*) ;; *) continue ;; esac
      last_row_ln=$ln
      if [ "$(printf '%s' "${line#- }" | awk -F' [|] ' '{print NF}')" -lt 4 ]; then
        fm_verify_gate_say "malformed Tester row (need '- <id>@<width> | <line> | pass | evidence: x'): $line"
        continue
      fi
      rid=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $1}')
      rstate=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $(NF-1)}')
      revidence=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $NF}')
      case "$known" in
        *$'\n'"$rid"$'\n'*) ;;
        *)
          if [ "$rstate" != retired ]; then
            fm_verify_gate_say "$rid is not a row of $issue"
          else
            case "$known_ids" in
              *$'\n'"${rid%%@*}"$'\n'*) fm_verify_gate_say "$rid is retired, but the issue still has ${rid%%@*}" ;;
            esac
          fi
          continue ;;
      esac
      case "$expected" in
        *$'\n'"$rid"$'\n'*)
          seen="$seen$rid"$'\n'
          want_text=$(fm_verify_gate_row_text "$(printf '%s\n' "$rows" | awk -v p="- $rid | " 'index($0, p) == 1 { print; exit }')")
          if [ "$(fm_verify_gate_row_text "$line")" != "$want_text" ]; then
            fm_verify_gate_say "$rid line differs from the issue: Tester '$(fm_verify_gate_row_text "$line")', issue '$want_text'"
          fi
          if [ "$rstate" != pass ]; then
            fm_verify_gate_say "$rid is '$rstate', not pass"
            continue
          fi
          case "$revidence" in
            'evidence: '*) ev=${revidence#evidence: } ;;
            *) fm_verify_gate_say "$rid has no 'evidence:' field"; continue ;;
          esac
          fm_verify_gate_evidence_problem "$rid" "$ev" "$tester_home"
          ;;
      esac
    done <"$tfile"
    # The verified line closes the record: it is the Tester's word on the rows above it only.
    verified_ln=$(grep -n '^verified: tester ' "$tfile" | tail -n 1 | cut -d: -f1)
    if [ -n "$verified_ln" ] && [ "$verified_ln" -le "$last_row_ln" ]; then
      fm_verify_gate_say "the 'verified: tester' line must come after the last scenario row (line $verified_ln, last row at line $last_row_ln)"
    fi
    while IFS= read -r rid; do
      [ -n "$rid" ] || continue
      case "$seen" in *$'\n'"$rid"$'\n'*) ;; *) fm_verify_gate_say "$rid is missing from the Tester record" ;; esac
    done <<<"$expected"
  fi
  return "$bad"
}

# fm_verify_gate_check <data-dir> <task-id> <base-dir>: returns 0 when the gate
# passes; otherwise prints every problem to stderr and returns 1.
fm_verify_gate_check() {  # <data-dir> <task-id> <base-dir>
  local problems
  problems=$(fm_verify_gate_problems "$1" "$2" "$3") || true
  [ -n "$problems" ] || return 0
  printf '%s\n' "$problems" | sed 's/^/  - /' >&2
  return 1
}
