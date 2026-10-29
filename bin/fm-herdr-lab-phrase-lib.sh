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
#   create, remove, delete, kill, spawn, with their -s, -ed, -ped and -ing forms)
#   within 60 characters of the word pane, assistance or agent, in either order,
#   ignoring case.
# fm_herdr_lab_brief_has <brief-file>   succeeds when the brief carries the lab
#   section heading that `bin/fm-brief.sh --herdr-lab` scaffolds.
# Log-only through bin/fm-enforce-lib.sh (check herdr-lab-brief).

fm_herdr_lab_phrase() {  # <text>
  local text=$1 verbs='(start(s|ed|ing)?|stop(s|ped|ping)?|restart(s|ed|ing)?|rotat[a-z]*|relaunch(es|ed|ing)?|clos[a-z]*|creat[a-z]*|remov[a-z]*|delet[a-z]*|kill(s|ed|ing)?|spawn(s|ed|ing)?)' nouns='(pane|assistance|agent)s?'
  # A period inside a file name (fm-assistance.sh stop) is not a sentence end: drop the
  # extension dot before the 60-character window so the verb and noun stay linked.
  printf '%s' "$text" | tr '\n' ' ' | sed -E 's/\.(sh|mjs|js|md|json|py)\b/ /g' | grep -oiE "\\b${verbs}\\b[^.]{0,60}\\b${nouns}\\b|\\b${nouns}\\b[^.]{0,60}\\b${verbs}\\b" | head -1
}

fm_herdr_lab_brief_has() {  # <brief-file>
  grep -qxF '# Herdr isolation - HARD SAFETY CONTRACT' "$1" 2>/dev/null
}
