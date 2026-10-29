#!/usr/bin/env bash
# Merge self-test gate for bin/fm-pr-merge.sh (spec huynhtandat223/firstmate#217,
# ticket #218). Log-only first: bin/fm-enforce-lib.sh owns the switch.
#
# fm_selftest_gate <pr-url> <task-id> <live-head> reads the PR body once with
# `gh pr view --json body` and checks it before a GitHub merge. It returns 1
# only when a hit's check holds `block` in config/enforce-<check>; otherwise
# each hit is one line in state/enforce-<check>.log and one "would refuse:"
# line on stderr, and the merge goes on.
#
# G1, check merge-selftest:
#   phrase            a body line outside fenced code and `>` quotes says
#                     "do not merge", "don't merge" or "not ready to merge"
#                     (every repository).
# Receipt rule, only for a task with surface=user-visible in state/<task>.meta
# on huynhtandat223/cfw-modules. The body needs
#   Self-test: verify-cfw run <features> --target storybook:<branch> head=<sha> PASS
# and data/<task>/selftest-<head>.json, written by the cfw-modules verify-cfw
# tool, must read PASS at the live head:
#   no-selftest-line  the body has no such line
#   stale-head        <sha> is not a prefix of the live head (9 or more hex)
#   no-receipt        no receipt file for that head
#   receipt-fail      the receipt is not PASS, holds a failed check or names
#                     another head
# Every receipt hit prints the verify-cfw command that produces a fresh receipt.
#
# Inputs from the caller (bin/fm-pr-merge.sh sets them): FM_HOME, STATE.
# FM_CONFIG_OVERRIDE moves the config directory, as in the other checks.

SELFTEST_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-enforce-lib.sh
. "$SELFTEST_GATE_DIR/fm-enforce-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SELFTEST_GATE_DIR/fm-pr-lib.sh"

FM_SELFTEST_CFW_REPO=huynhtandat223/cfw-modules
FM_SELFTEST_REFUSED=0

# One hit: log it, tell stderr, and remember when its check blocks.
# fm_selftest_hit <check> <code> <text>
fm_selftest_hit() {
  local check=$1 code=$2 text=$3 mode
  mode=$(fm_enforce_mode "$FM_SELFTEST_CONFIG" "$check")
  if [ "$mode" = block ]; then
    fm_enforce_log "$FM_SELFTEST_STATE" "$check" refuse "$code" "$text"
    printf 'refused: %s %s\n' "$code" "$text" >&2
    FM_SELFTEST_REFUSED=1
  else
    fm_enforce_log "$FM_SELFTEST_STATE" "$check" would-refuse "$code" "$text"
    printf 'would refuse: %s %s\n' "$code" "$text" >&2
  fi
}

# Prints "<line number><TAB><line>" for each body line, outside fenced code and
# `>` quotes, that says the change must not merge yet.
# fm_selftest_phrase_hits <body-file>
fm_selftest_phrase_hits() {
  local body=$1 line trimmed lower n=0 fence='' marker
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      '```'*|'~~~'*)
        marker=${trimmed%%[!\`~]*}
        if [ -z "$fence" ]; then
          fence=$marker
        elif [ "${marker:0:1}" = "${fence:0:1}" ] && [ "${#marker}" -ge "${#fence}" ] \
          && [ -z "${trimmed#"$marker"}" ]; then
          fence=''
        fi
        continue
        ;;
    esac
    [ -z "$fence" ] || continue
    case "$trimmed" in '>'*) continue ;; esac
    lower=${line,,}
    lower=${lower//’/\'}
    case "$lower" in
      *"do not merge"*|*"don't merge"*|*"not ready to merge"*)
        printf '%s\t%s\n' "$n" "$trimmed"
        ;;
    esac
  done < "$body"
}

# The first Self-test line outside fences and quotes, or nothing. Prints
# "<features><TAB><branch><TAB><sha>".
# fm_selftest_line <body-file>
fm_selftest_line() {
  local body=$1 line trimmed fence='' marker
  local re='^Self-test:[[:space:]]+verify-cfw[[:space:]]+run[[:space:]]+([^[:space:]]+)[[:space:]]+--target[[:space:]]+storybook:([^[:space:]]+)[[:space:]]+head=([0-9a-fA-F]{9,})[[:space:]]+PASS[[:space:]]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      '```'*|'~~~'*)
        marker=${trimmed%%[!\`~]*}
        if [ -z "$fence" ]; then
          fence=$marker
        elif [ "${marker:0:1}" = "${fence:0:1}" ] && [ "${#marker}" -ge "${#fence}" ] \
          && [ -z "${trimmed#"$marker"}" ]; then
          fence=''
        fi
        continue
        ;;
    esac
    [ -z "$fence" ] || continue
    case "$trimmed" in '>'*) continue ;; esac
    if [[ "$trimmed" =~ $re ]]; then
      printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
      return 0
    fi
  done < "$body"
  return 0
}

# The receipt rule for one user-visible cfw-modules task.
# fm_selftest_receipt_rule <body-file> <task-id> <live-head>
fm_selftest_receipt_rule() {
  local body=$1 task=$2 head=$3 found features branch sha receipt result_head out
  local out_dir="$FM_HOME/data/$task" cmd
  found=$(fm_selftest_line "$body")
  features='<features>'
  branch='<branch>'
  if [ -n "$found" ]; then
    IFS=$'\t' read -r features branch sha <<< "$found"
  fi
  cmd="npm run verify-cfw -- run $features --target storybook:$branch --head $head --widths 1440,390 --json --out $out_dir/"
  if [ -z "$found" ]; then
    fm_selftest_hit merge-selftest no-selftest-line \
      "the PR body has no \"Self-test: verify-cfw run <features> --target storybook:<branch> head=<sha> PASS\" line; run: $cmd"
    return 0
  fi
  sha=${sha,,}
  case "${head,,}" in
    "$sha"*) ;;
    *)
      fm_selftest_hit merge-selftest stale-head \
        "the Self-test line names head=$sha but the live head is $head; run: $cmd"
      return 0
      ;;
  esac
  receipt=
  for out in "$out_dir/selftest-$head.json" "$out_dir/selftest-$sha.json"; do
    [ -f "$out" ] && { receipt=$out; break; }
  done
  if [ -z "$receipt" ]; then
    fm_selftest_hit merge-selftest no-receipt \
      "no receipt data/$task/selftest-$head.json; run: $cmd"
    return 0
  fi
  if ! result_head=$(jq -r '
        if type != "object" then error("not an object") else
          (if ((.result // "") == "PASS") and ([.results[]? | select(.result == "fail")] | length == 0)
           then "pass" else "fail" end) + "\t" + ((.head // "") | tostring)
        end' "$receipt" 2>/dev/null); then
    fm_selftest_hit merge-selftest receipt-fail \
      "the receipt $receipt is not readable JSON; run: $cmd"
    return 0
  fi
  local verdict=${result_head%%$'\t'*} receipt_head=${result_head#*$'\t'}
  if [ "$verdict" != pass ]; then
    fm_selftest_hit merge-selftest receipt-fail \
      "the receipt $receipt does not read PASS; run: $cmd"
    return 0
  fi
  receipt_head=${receipt_head,,}
  case "${head,,}" in
    "$receipt_head"*) [ "${#receipt_head}" -ge 9 ] || receipt_head= ;;
    *) receipt_head= ;;
  esac
  if [ -z "$receipt_head" ]; then
    fm_selftest_hit merge-selftest receipt-fail \
      "the receipt $receipt names another head than the live head $head; run: $cmd"
  fi
  return 0
}

fm_selftest_gate() {  # <pr-url> <task-id> <live-head>
  local url=$1 task=$2 head=$3 repo surface body line n text json
  FM_SELFTEST_CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  FM_SELFTEST_STATE=${STATE:-$FM_HOME/state}
  FM_SELFTEST_REFUSED=0
  repo=$( fm_pr_url_parse "$url" && printf '%s/%s' "$FM_PR_OWNER" "$FM_PR_REPO" ) || repo=
  body=$(mktemp "${TMPDIR:-/tmp}/fm-selftest-body.XXXXXX") || return 0
  if ! json=$(gh pr view "$url" --json body 2>/dev/null) || [ -z "$json" ] \
    || ! printf '%s' "$json" | jq -r '.body // ""' > "$body" 2>/dev/null; then
    fm_selftest_hit merge-selftest body-unread "could not read the PR body of $url"
    rm -f "$body"
    [ "$FM_SELFTEST_REFUSED" -eq 0 ] || return 1
    return 0
  fi
  while IFS=$'\t' read -r n text; do
    [ -n "$n" ] || continue
    fm_selftest_hit merge-selftest phrase "body line $n: $text"
  done < <(fm_selftest_phrase_hits "$body")
  surface=
  if [ -f "$FM_SELFTEST_STATE/$task.meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in surface=*) surface=${line#surface=} ;; esac
    done < "$FM_SELFTEST_STATE/$task.meta"
  fi
  if [ "$surface" = user-visible ] && [ "$repo" = "$FM_SELFTEST_CFW_REPO" ]; then
    fm_selftest_receipt_rule "$body" "$task" "$head"
  fi
  rm -f "$body"
  [ "$FM_SELFTEST_REFUSED" -eq 0 ] || return 1
  return 0
}
