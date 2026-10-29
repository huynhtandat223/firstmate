#!/usr/bin/env bash
# Herdr-lab brief check helpers (spec huynhtandat223/firstmate#200, E8a).
# A task that starts, stops, rotates or otherwise drives a pane or an assistance
# needs the isolation block that `bin/fm-brief.sh --herdr-lab` adds; without it a
# worker can touch the captain's live panes. bin/fm-brief.sh --check and
# bin/fm-send.sh use these two functions, and both refusals say
# "re-scaffold with --herdr-lab".
#
# fm_herdr_lab_phrase <text>   prints the first lifecycle phrase found, or nothing:
#   a lifecycle verb (start, stop, restart, rotate or rotation, relaunch, close,
#   create, remove, delete, kill, spawn) within 60 characters of the word pane or
#   assistance, in either order, ignoring case.
# fm_herdr_lab_brief_has <brief-file>   succeeds when the brief carries the lab block.
# Log-only through bin/fm-enforce-lib.sh (check herdr-lab-brief).

fm_herdr_lab_phrase() {  # <text>
  local text=$1 verbs='(start|stop|restart|rotat[a-z]*|relaunch|clos[a-z]*|creat[a-z]*|remov[a-z]*|delet[a-z]*|kill|spawn)' nouns='(pane|assistance)s?'
  printf '%s' "$text" | tr '\n' ' ' | grep -oiE "\\b${verbs}\\b[^.]{0,60}\\b${nouns}\\b|\\b${nouns}\\b[^.]{0,60}\\b${verbs}\\b" | head -1
}

fm_herdr_lab_brief_has() {  # <brief-file>
  # shellcheck disable=SC2016  # the backticks are literal brief text
  grep -qF 'explicitly scaffolded with `--herdr-lab`' "$1" 2>/dev/null
}
