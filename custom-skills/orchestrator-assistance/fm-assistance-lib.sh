#!/usr/bin/env bash
# fm-assistance-lib.sh - the single owner of orchestrator-assistance IDENTITY.
#
# Assistance is a read-only companion bound to exactly one live programme
# supervisor. This library owns the five facts that binding needs and nothing
# else: what the assistance task is called, where the parent's record lives, how
# the parent's observable history is found, where this binding's durable
# sidecars sit, and what a deliverable reminder looks like.
#
# WHY THIS FILE EXISTS AS A SEPARATE LIBRARY
# The skill owns watch semantics - which rules are watched, which cue matches,
# what a reminder says. This file owns none of that. Keeping the split physical
# is what stops the runtime from growing into a second orchestration authority:
# every function here answers "which parent, which record, which form", and a
# function that answered "which rule applies" would not belong.
#
# It defines functions and constants only and has no side effects on source.
# It is `set -u` and `set -e` safe.

# The assistance runtime is pinned, not routed. Assistance is one fixed reading
# job against one parent, so per-task dispatch profiles do not apply to it.
# shellcheck disable=SC2034 # Read by fm-assistance.sh, which sources this file.
FM_ASSISTANCE_HARNESS="pi"
# shellcheck disable=SC2034 # Read by fm-assistance.sh, which sources this file.
FM_ASSISTANCE_MODEL="cx/gpt-5.6-luna"
# shellcheck disable=SC2034 # Read by fm-assistance.sh, which sources this file.
FM_ASSISTANCE_EFFORT="xhigh"

# The closed set of deliverable forms. A reminder that is not one of these is
# refused before delivery, which is how the read-only boundary is enforced by
# construction rather than by the sending agent remembering it: a business
# decision, a stop, a gate, and a merge instruction have no form to travel in.
FM_ASSISTANCE_FORMS="WATCH REMINDER FINDING CLEAR UNPROVEN"

# The assistance task id for a programme. One programme, one assistance task.
fm_assistance_task_id() {  # <programme-id>
  printf '%s-assistance\n' "$1"
}

# Path to a task's recorded metadata inside one firstmate home.
fm_assistance_meta_path() {  # <fm-home> <task-id>
  printf '%s/state/%s.meta\n' "$1" "$2"
}

# Last recorded value of a meta key, empty when the key is absent. Last wins:
# fm-spawn appends, so a re-recorded field must not resolve to a stale first
# occurrence (the real parent meta carries parent_home= three times).
fm_assistance_meta_field() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# Claude stores one project's session history under a directory named after the
# project path with every '/' and '.' replaced by '-'.
fm_assistance_history_dir_name() {  # <worktree>
  printf '%s\n' "$1" | tr '/.' '--'
}

# Root of the Claude session-history store. Overridable so a test can bind a
# fixture history without writing into the operator's real home.
fm_assistance_history_root() {
  printf '%s\n' "${FM_ASSISTANCE_HISTORY_ROOT:-$HOME/.claude/projects}"
}

# The parent's current session-history file: the most recently modified .jsonl
# in its project's history directory, which is the session still being appended
# to. Prints nothing and returns 1 when the store, the directory, or a session
# file is absent, so the caller reports a missing capability instead of
# substituting a guessed channel.
fm_assistance_history_file() {  # <worktree>
  local dir found
  dir="$(fm_assistance_history_root)/$(fm_assistance_history_dir_name "$1")"
  [ -d "$dir" ] || return 1
  # shellcheck disable=SC2012 # Claude names these files by session UUID, so
  # they carry no whitespace, and ls -t is the portable mtime sort here.
  found=$(ls -1t "$dir"/*.jsonl 2>/dev/null | head -n 1)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Durable sidecars for one binding, following this repo's state/<id>.* layout so
# an assistance task cleans up with the ordinary teardown that removes them.
fm_assistance_binding_path() {  # <fm-home> <programme-id>
  printf '%s/state/%s.assistance-binding\n' "$1" "$(fm_assistance_task_id "$2")"
}

fm_assistance_cursor_path() {  # <fm-home> <programme-id>
  printf '%s/state/%s.assistance-cursor\n' "$1" "$(fm_assistance_task_id "$2")"
}

fm_assistance_sent_path() {  # <fm-home> <programme-id>
  printf '%s/state/%s.assistance-sent\n' "$1" "$(fm_assistance_task_id "$2")"
}

# Stable short identity for one reminder. The inputs are the watch item, the
# visible action, and the evidence identity, so the same point about the same
# evidence fingerprints identically no matter how the sentence is worded - a new
# turn, elapsed time, or a parent pause changes nothing.
fm_assistance_fingerprint() {  # <watch-id> <action> <evidence>
  printf '%s\037%s\037%s' "$1" "$2" "$3" | sha256sum | cut -c1-16
}

# 0 when the text opens with one of the closed delivery forms.
fm_assistance_form_ok() {  # <text>
  local form
  for form in $FM_ASSISTANCE_FORMS; do
    case "$1" in
      "${form} "*|"${form}["*) return 0 ;;
    esac
  done
  return 1
}

# Digest of the exact skill revision an assistance session is running. A reread
# is proven by this value changing, never by the session saying it reread.
fm_assistance_skill_digest() {  # <skill-path>
  [ -f "$1" ] || return 1
  sha256sum "$1" | cut -c1-16
}

# A programme is live unless its own status log records an explicit terminal
# result. Pause, waiting, blockage, and an absent log are all nonterminal: the
# companion outlives every ordinary quiet stretch of the programme it watches.
fm_assistance_parent_state() {  # <status-file>
  local last
  [ -f "$1" ] || { printf 'live\n'; return 0; }
  last=$(grep -E '^(working|needs-decision|blocked|paused|done|failed|resolved):' "$1" 2>/dev/null | tail -n 1)
  case "$last" in
    done:*|failed:*) printf 'terminal\n' ;;
    *) printf 'live\n' ;;
  esac
}
