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
# on huynhtandat223/cfw-modules (the name is matched without regard to case). The body needs
#   Self-test: verify-cfw run <features> --target storybook:<branch> head=<sha> PASS
# (a body may keep older lines; the line whose sha prefixes the live head is read)
# and data/<task>/selftest-<head>.json, written by the cfw-modules verify-cfw
# tool, must read PASS at the live head:
#   no-selftest-line  the body has no such line
#   stale-head        <sha> is not a prefix of the live head (9 or more hex)
#   no-receipt        no receipt file for that head
#   receipt-fail      the receipt is not PASS, holds a failed check, names
#                     another head, or is not the run the Self-test line names
#                     (other features, another target, or widths without both
#                     1440 and 390)
# Every receipt hit prints the verify-cfw command that produces a fresh receipt.
#
# G2, check merge-verifier: the receipt G1 reads must carry an `actor` other
# than the task id.
#   author-receipt    the receipt's actor is the task itself
#   no-actor          the receipt names no actor
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

# Prints "<line number><TAB><line>" for each body line outside fenced code and
# `>` quotes. A fence opens on 3 or more backticks or tildes and closes on the
# same character, at least as long, with nothing but whitespace after it.
# fm_selftest_plain_lines <body-file>
fm_selftest_plain_lines() {
  local body=$1 line trimmed rest n=0 fence='' marker
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      '```'*|'~~~'*)
        marker=${trimmed%%[!\`~]*}
        rest=${trimmed#"$marker"}
        if [ -z "$fence" ]; then
          fence=$marker
        elif [ "${marker:0:1}" = "${fence:0:1}" ] && [ "${#marker}" -ge "${#fence}" ] \
          && [ -z "${rest//[[:space:]]/}" ]; then
          fence=''
        fi
        continue
        ;;
    esac
    [ -z "$fence" ] || continue
    case "$trimmed" in '>'*) continue ;; esac
    printf '%s\t%s\n' "$n" "$trimmed"
  done < "$body"
}

# Prints "<line number><TAB><line>" for each plain body line that says the
# change must not merge yet.
# fm_selftest_phrase_hits <body-file>
fm_selftest_phrase_hits() {
  local n text lower
  while IFS=$'\t' read -r n text; do
    lower=${text,,}
    lower=${lower//’/\'}
    case "$lower" in
      *"do not merge"*|*"don't merge"*|*"not ready to merge"*)
        printf '%s\t%s\n' "$n" "$text"
        ;;
    esac
  done < <(fm_selftest_plain_lines "$1")
}

# The plain Self-test line for the live head, or nothing. A body may keep older
# lines, so the line whose sha is a prefix of the live head wins; with none, the
# first line is returned, for the stale-head message. Prints
# "<features><TAB><branch><TAB><sha>".
# fm_selftest_line <body-file> <live-head>
fm_selftest_line() {
  local n text first='' live=${2,,}
  local re='^Self-test:[[:space:]]+verify-cfw[[:space:]]+run[[:space:]]+([^[:space:]]+)[[:space:]]+--target[[:space:]]+storybook:([^[:space:]]+)[[:space:]]+head=([0-9a-fA-F]{9,})[[:space:]]+PASS[[:space:]]*$'
  while IFS=$'\t' read -r n text; do
    if [[ "$text" =~ $re ]]; then
      local found
      found=$(printf '%s\t%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
      case "$live" in
        "${BASH_REMATCH[3],,}"*) printf '%s\n' "$found"; return 0 ;;
      esac
      [ -n "$first" ] || first=$found
    fi
  done < <(fm_selftest_plain_lines "$1")
  [ -z "$first" ] || printf '%s\n' "$first"
  return 0
}

# The receipt rule for one user-visible cfw-modules task.
# fm_selftest_receipt_rule <body-file> <task-id> <live-head>
fm_selftest_receipt_rule() {
  local body=$1 task=$2 head=$3 found features branch sha receipt result_head out
  local out_dir="$FM_HOME/data/$task" cmd
  found=$(fm_selftest_line "$body" "$head")
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
          [ (if ((.result // "") == "PASS") and ([.results[]? | select(.result == "fail")] | length == 0)
             then "pass" else "fail" end),
            ((.head // "") | tostring),
            ((.actor // "") | tostring),
            ((.features // []) | if type == "array" then (map(tostring) | unique | join(",")) else "" end),
            ((.target // "") | tostring),
            ((.widths // []) | if type == "array" then (map(tostring) | join(",")) else "" end)
          ] | join("\u001f")
        end' "$receipt" 2>/dev/null); then
    fm_selftest_hit merge-selftest receipt-fail \
      "the receipt $receipt is not readable JSON; run: $cmd"
    return 0
  fi
  local verdict receipt_head actor receipt_features receipt_target receipt_widths
  IFS=$'\x1f' read -r verdict receipt_head actor receipt_features receipt_target receipt_widths <<< "$result_head"
  # G2: the receipt must come from a verifier that is not the task's author.
  if [ -z "$actor" ]; then
    fm_selftest_hit merge-verifier no-actor \
      "the receipt $receipt names no actor, so the verifier is unknown; run: $cmd"
  elif [ "$actor" = "$task" ]; then
    fm_selftest_hit merge-verifier author-receipt \
      "the receipt $receipt names actor $actor, the author of this change: the verifier is not the author: the Tester or a fresh verifier session runs it; run: $cmd"
  fi
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
    return 0
  fi
  # The receipt must be the run the Self-test line names: same features, same
  # target, and both widths.
  local line_features differs=''
  line_features=$(printf '%s\n' "$features" | tr ',' '\n' | sort -u | paste -sd, -)
  [ "$receipt_features" = "$line_features" ] \
    || differs="$differs; the receipt ran features ${receipt_features:-none} but the Self-test line names $line_features"
  [ "$receipt_target" = "storybook:$branch" ] \
    || differs="$differs; the receipt ran target ${receipt_target:-none} but the Self-test line names storybook:$branch"
  local width
  for width in 1440 390; do
    case ",$receipt_widths," in
      *",$width,"*) ;;
      *) differs="$differs; the receipt widths (${receipt_widths:-none}) lack $width" ;;
    esac
  done
  if [ -n "$differs" ]; then
    fm_selftest_hit merge-selftest receipt-fail \
      "the receipt $receipt is not the run the Self-test line names${differs}; run: $cmd"
  fi
  return 0
}

fm_selftest_gate() {  # <pr-url> <task-id> <live-head>
  local url=$1 task=$2 head=$3 repo surface body line n text json
  FM_SELFTEST_CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  FM_SELFTEST_STATE=${STATE:-$FM_HOME/state}
  FM_SELFTEST_REFUSED=0
  repo=$( fm_pr_url_parse "$url" && printf '%s/%s' "$FM_PR_OWNER" "$FM_PR_REPO" ) || repo=
  repo=${repo,,}
  if ! body=$(mktemp "${TMPDIR:-/tmp}/fm-selftest-body.XXXXXX"); then
    fm_selftest_hit merge-selftest body-unread "could not stage the PR body of $url for the checks (no temp file)"
    [ "$FM_SELFTEST_REFUSED" -eq 0 ] || return 1
    return 0
  fi
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
