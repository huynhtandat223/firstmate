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
#
# Pi has no permission system: assistance crewmates are autonomous, so the
# runtime enforces no read-only boundary here and this comment must not promise
# a Pi equivalent of `--mode plan`.
#
# The boundary that actually holds is construction. FM_ASSISTANCE_FORMS is a
# closed set of deliverable forms, so a business decision, a stop, a gate, or a
# merge instruction has no form to travel in; fm-assistance.sh remind refuses
# anything else before delivery.
#
# The former agy rationale already recorded that bin/fm-spawn.sh hardcoded
# --dangerously-skip-permissions and passed no --mode plan, so the claimed agy
# read-only runtime boundary was not active for an assistance launch. Switching
# to Pi therefore does not remove a protection that was working; it changes the
# autonomous runtime while preserving the forms boundary above.
#
# Pi's launch-profile axes and supported thinking levels are owned by the
# harness-adapters skill; this file pins the assistance choice only.
# shellcheck disable=SC2034 # Read by fm-assistance.sh, which sources this file.
FM_ASSISTANCE_HARNESS="pi"
# shellcheck disable=SC2034 # Read by fm-assistance.sh, which sources this file.
FM_ASSISTANCE_MODEL="cx/gpt-5.6-luna"
# shellcheck disable=SC2034 # Read by fm-assistance.sh, which sources this file.
FM_ASSISTANCE_EFFORT="high"

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

fm_assistance_primary_history_root() {
  printf '%s\n' "${FM_ASSISTANCE_PRIMARY_HISTORY_ROOT:-$HOME/.pi/agent/sessions}"
}

# Every session history recorded for one project worktree, one path per line.
fm_assistance_history_candidates() {  # <worktree>
  local dir path
  dir="$(fm_assistance_history_root)/$(fm_assistance_history_dir_name "$1")"
  [ -d "$dir" ] || return 1
  for path in "$dir"/*.jsonl; do
    [ -f "$path" ] && printf '%s\n' "$path"
  done
}

# The parent's session history, resolved to ONE exact file.
#
# A programme supervisor's worktree can hold several recorded sessions, and the
# supervisor's own metadata carries no session identity, so "newest" is not an
# identity: a later write to any other session in that directory would silently
# move the binding to a transcript that is not the parent's. This function
# therefore resolves only what is unambiguous.
#
# Exit codes are the caller's whole vocabulary:
#   0  one exact history, printed
#   1  no store, no directory, or no session file at all
#   2  several candidates and no pin - the caller must ask for one
fm_assistance_primary_history_file() {  # <worktree> <session-uuid>
  local worktree=$1 pin=$2 root candidate
  [ -n "$pin" ] || return 1
  root=$(fm_assistance_primary_history_root)
  while IFS= read -r candidate; do
    if python3 - "$candidate" "$pin" "$worktree" <<'PY2'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        record = json.loads(stream.readline())
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if record.get("type") == "session" and record.get("id") == sys.argv[2] and record.get("cwd") == sys.argv[3] else 1)
PY2
    then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$root" -type f -name "*_${pin}.jsonl" -print 2>/dev/null)
  return 1
}

fm_assistance_history_file() {  # <worktree> [pin]
  local worktree=$1 pin=${2:-} candidates count match
  candidates=$(fm_assistance_history_candidates "$worktree") || return 1
  [ -n "$candidates" ] || return 1

  if [ -n "$pin" ]; then
    # A pin is an absolute path or a session id; either must name a real
    # candidate, so a typo refuses instead of falling back to a guess.
    match=$(printf '%s\n' "$candidates" | grep -F -x -- "$pin" || true)
    [ -n "$match" ] || match=$(printf '%s\n' "$candidates" | grep -F -- "/$pin.jsonl" || true)
    [ -n "$match" ] || return 1
    [ "$(printf '%s\n' "$match" | wc -l)" -eq 1 ] || return 2
    printf '%s\n' "$match"
    return 0
  fi

  count=$(printf '%s\n' "$candidates" | wc -l)
  [ "$count" -eq 1 ] || return 2
  printf '%s\n' "$candidates"
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

# A pending observation batch is the uncommitted half of observation. It keeps
# the old cursor, the proposed next cursor, and every emitted turn identity
# until each turn has one durable outcome.
fm_assistance_pending_path() {  # <fm-home> <programme-id>
  printf '%s/state/%s.assistance-pending\n' "$1" "$(fm_assistance_task_id "$2")"
}

# One outcome per pending turn. The outcome is written before the committed
# cursor moves, so a restart can finish the contiguous prefix safely.
fm_assistance_outcomes_path() {  # <fm-home> <programme-id>
  printf '%s/state/%s.assistance-outcomes\n' "$1" "$(fm_assistance_task_id "$2")"
}

# Successful sends bound to a specific observed turn. A delivered settlement
# must point at one of these exact-parent records.
fm_assistance_deliveries_path() {  # <fm-home> <programme-id>
  printf '%s/state/%s.assistance-deliveries\n' "$1" "$(fm_assistance_task_id "$2")"
}

# Stable short identity for one reminder. The inputs are the watch item, the
# visible action, and the evidence identity, so the same point about the same
# evidence fingerprints identically no matter how the sentence is worded - a new
# turn, elapsed time, or a parent pause changes nothing.
fm_assistance_fingerprint() {  # <watch-id> <action> <evidence>
  printf '%s\037%s\037%s' "$1" "$2" "$3" | sha256sum | cut -c1-16
}

# Identity of a successful exact-parent send. The reminder fingerprint remains
# the deduplication key; this second fingerprint proves the target and bytes
# that were actually delivered for a settlement.
fm_assistance_delivery_fingerprint() {  # <parent-task> <turn-id> <reminder-fp> <text>
  printf '%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" | sha256sum | cut -c1-16
}

# State fields are line-oriented and deliberately reject tabs/newlines. This
# keeps sidecars parseable without inventing a second serialization format.
fm_assistance_field_ok() {  # <value>
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
    *) return 0 ;;
  esac
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
