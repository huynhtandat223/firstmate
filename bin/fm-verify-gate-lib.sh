#!/usr/bin/env bash
# Single owner of the user-visible done gate: the verification record
# data/<task-id>/verify.md that bin/fm-teardown.sh requires before it cleans up a
# ship task recorded with surface=user-visible (bin/fm-spawn.sh --surface).
# Sourced by bin/fm-teardown.sh. The wording a worker reads lives in
# bin/fm-dod-lib.sh.
# Record format, written by firstmate:
#   surface: user-visible
#   ## Acceptance
#   - A1 | <acceptance line> | pass | evidence: <existing file path or http(s) URL>
#   - A2 | <acceptance line> | pending | evidence: -
#   approved: firstmate <epoch>
# fm_verify_gate_problems <data-dir> <task-id> <base-dir> prints one problem per
# line on stdout and returns 1 when the record is missing or incomplete; it prints
# nothing and returns 0 when every acceptance line is pass with evidence and an
# approved line follows the last acceptance line. An acceptance-shaped line
# outside '## Acceptance' is a problem, never skipped. A relative evidence path resolves against <base-dir>.
# The check reads the record only; it never generates or changes evidence.

fm_verify_gate_problems() {  # <data-dir> <task-id> <base-dir>
  local data=$1 id=$2 base=$3 file first line n=0 in_acc=0 approved=0 saw_heading=0
  local rid rtext rstatus revidence ev path
  file="$data/$id/verify.md"
  if [ ! -f "$file" ]; then
    echo "verification record missing: $file"
    return 1
  fi
  first=$(sed -n '1p' "$file")
  [ "$first" = 'surface: user-visible' ] || echo "line 1 must be 'surface: user-visible' (found '$first')"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## Acceptance') in_acc=1; saw_heading=1; continue ;;
      '#'*) in_acc=0; continue ;;
      'approved: firstmate '*)
        case "${line#approved: firstmate }" in
          ''|*[!0-9]*) echo "approved line needs a numeric epoch: $line" ;;
          *)
            if [ "$n" -gt 0 ]; then approved=1
            else echo "approved line must come after the last acceptance line: $line"; fi ;;
        esac
        continue ;;
    esac
    if [ "$in_acc" -eq 0 ]; then
      case "$line" in
        '- A'[0-9]*' | '*) echo "acceptance line outside '## Acceptance': $line" ;;
      esac
      continue
    fi
    case "$line" in '- '*) ;; *) continue ;; esac
    n=$((n + 1))
    approved=0
    rid=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $1}')
    rstatus=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $(NF-1)}')
    revidence=$(printf '%s' "${line#- }" | awk -F' [|] ' '{print $NF}')
    if [ "$(printf '%s' "${line#- }" | awk -F' [|] ' '{print NF}')" -lt 4 ]; then
      echo "malformed acceptance line (need '- Ax | line | pass | evidence: x'): $line"
      continue
    fi
    if [ "$rstatus" != pass ]; then
      echo "$rid is '$rstatus', not pass"
      continue
    fi
    case "$revidence" in
      'evidence: '*) ev=${revidence#evidence: } ;;
      *) echo "$rid has no 'evidence:' field"; continue ;;
    esac
    case "$ev" in
      http://?*|https://?*) ;;
      ''|-) echo "$rid is pass without evidence" ;;
      /*) [ -e "$ev" ] || echo "$rid evidence path does not exist: $ev" ;;
      *) path="$base/$ev"; [ -e "$path" ] || echo "$rid evidence path does not exist: $ev" ;;
    esac
  done <"$file"
  [ "$saw_heading" -eq 1 ] || echo "missing '## Acceptance' heading"
  [ "$n" -gt 0 ] || echo "no acceptance lines under '## Acceptance'"
  [ "$approved" -eq 1 ] || echo "missing 'approved: firstmate <epoch>' line"
  return 0
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
