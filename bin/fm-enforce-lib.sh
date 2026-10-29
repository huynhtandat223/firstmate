#!/usr/bin/env bash
# Log-only-first switch for harness checks (spec huynhtandat223/firstmate#200).
# A check that can block asks fm_enforce_mode for its verdict: it blocks only
# when config/enforce-<check> holds the word `block` on its first line that is
# not blank or a comment. A missing, empty or any other file means `log`, so a
# new check runs for a day writing each hit to state/enforce-<check>.log and
# blocks nothing until firstmate reviews that log and sets the file.
# fm_enforce_mode <config-dir> <check> prints block or log.
# fm_enforce_log <state-dir> <check> <mode> <code> <text> appends one line,
# "<epoch><TAB><mode><TAB><code><TAB><text>", and never fails its caller.

fm_enforce_mode() {  # <config-dir> <check>
  local file="$1/enforce-$2" line word
  [ -f "$file" ] && [ -r "$file" ] || { printf 'log\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    word=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$word" in
      ''|'#'*) continue ;;
      block) printf 'block\n'; return 0 ;;
      *) break ;;
    esac
  done < "$file"
  printf 'log\n'
}

fm_enforce_log() {  # <state-dir> <check> <mode> <code> <text>
  local state=$1 check=$2 mode=$3 code=$4 text=$5
  text=$(printf '%s' "$text" | tr '\t\n\r' '   ')
  mkdir -p "$state" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$mode" "$code" "$text" >> "$state/enforce-$check.log" 2>/dev/null || true
  return 0
}
