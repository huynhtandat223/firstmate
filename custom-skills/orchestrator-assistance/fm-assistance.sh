#!/usr/bin/env bash
# fm-assistance.sh - bind, open, and run one read-only assistance companion for
# one live programme supervisor.
#
# Usage:
#   fm-assistance.sh bind <programme-id>
#   fm-assistance.sh open <programme-id> [--relaunch]
#   fm-assistance.sh observe <programme-id> [--limit N] [--replay-until <uuid>]
#   fm-assistance.sh remind <programme-id> --id <watch-id> --action <action>
#                    --evidence <identity> <text...>
#   fm-assistance.sh lifecycle <programme-id>
#   fm-assistance.sh reload <programme-id>
#
# WHAT THIS OWNS
# Identity, idempotency, the observation cursor, the delivery form, and
# lifecycle. It owns no watch semantics: which rules are watched, which cue a
# parent turn matches, and what a reminder should say all stay in SKILL.md.
# A subcommand that decided a rule would be a second orchestration authority.
#
# THE BINDING
# `bind` resolves the parent supervisor's own recorded metadata, refuses a task
# that is not a supervisor, resolves that supervisor's observable Claude session
# history from its recorded worktree, and writes state/<id>.assistance-binding.
# Everything after it reads that binding, so no later step re-guesses a parent.
#
# ONE SESSION
# `open` is idempotent on the record: a programme whose assistance task is
# already recorded resumes it and reloads the current skill revision instead of
# spawning a second one. `--relaunch` is the explicit path for a recorded
# session whose process is gone; it returns to the same recorded home.
#
# OBSERVATION
# `observe` reads new parent turns after the durable cursor and advances it.
# `--replay-until <uuid>` instead reads from the start and stops BEFORE that
# record, without touching the cursor, so replaying history can never carry a
# later correction back into the input that is supposed to precede it.
#
# DELIVERY
# `remind` sends one line to the exact parent task, and only in one of the forms
# in FM_ASSISTANCE_FORMS. It never passes --resolve-key, so assistance cannot
# close a parent decision. A repeat of an unchanged fingerprint is suppressed
# without delivery, and a fingerprint is recorded only after delivery succeeds,
# so a failed send stays retryable.
#
# ENVIRONMENT
#   FM_HOME                     firstmate home holding state/ (default: this repo)
#   FM_ASSISTANCE_HISTORY_ROOT  Claude session store (default: ~/.claude/projects)
#   FM_SEND / FM_SPAWN          delivery and launch commands, overridable so a
#                               test can exercise this seam without driving a
#                               live pane
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=custom-skills/orchestrator-assistance/fm-assistance-lib.sh
. "$SCRIPT_DIR/fm-assistance-lib.sh"

FM_HOME="${FM_HOME:-$FM_ROOT}"
FM_SEND="${FM_SEND:-$FM_ROOT/bin/fm-send.sh}"
FM_SPAWN="${FM_SPAWN:-$FM_ROOT/bin/fm-spawn.sh}"
SKILL_PATH="$SCRIPT_DIR/SKILL.md"

die() { printf 'fm-assistance: %s\n' "$1" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

need_programme() {
  [ -n "${1:-}" ] || die "name the programme id"
}

binding_get() {  # <binding-file> <key>
  fm_assistance_meta_field "$1" "$2"
}

require_binding() {  # <programme-id> -> echoes binding path
  local binding
  binding=$(fm_assistance_binding_path "$FM_HOME" "$1")
  [ -f "$binding" ] || die "no assistance binding for $1; run: fm-assistance.sh bind $1"
  printf '%s\n' "$binding"
}

# --- bind -------------------------------------------------------------------

cmd_bind() {
  local pid parent_meta kind worktree history binding digest
  pid="${1:-}"; need_programme "$pid"

  parent_meta=$(fm_assistance_meta_path "$FM_HOME" "$pid")
  [ -f "$parent_meta" ] || die "no supervisor record for $pid at $parent_meta"

  kind=$(fm_assistance_meta_field "$parent_meta" kind)
  [ "$kind" = "supervisor" ] || die "$pid is recorded as kind=${kind:-none}; assistance binds only to a programme supervisor"

  worktree=$(fm_assistance_meta_field "$parent_meta" worktree)
  [ -n "$worktree" ] || die "$pid records no worktree, so its session history cannot be resolved"

  history=$(fm_assistance_history_file "$worktree") \
    || die "no readable session history for $pid under $(fm_assistance_history_root)/$(fm_assistance_history_dir_name "$worktree"); assistance needs that observable source"

  digest=$(fm_assistance_skill_digest "$SKILL_PATH") || die "assistance skill missing at $SKILL_PATH"

  binding=$(fm_assistance_binding_path "$FM_HOME" "$pid")
  mkdir -p "$(dirname "$binding")"
  {
    printf 'programme_id=%s\n' "$pid"
    printf 'parent_task_id=%s\n' "$pid"
    printf 'assistance_task_id=%s\n' "$(fm_assistance_task_id "$pid")"
    printf 'parent_worktree=%s\n' "$worktree"
    printf 'parent_history=%s\n' "$history"
    printf 'skill_path=%s\n' "$SKILL_PATH"
    printf 'skill_digest=%s\n' "$digest"
    printf 'bound_at=%s\n' "$(date -Iseconds)"
  } > "$binding"

  printf 'bound %s parent=%s history=%s skill=%s\n' \
    "$(fm_assistance_task_id "$pid")" "$pid" "$history" "$digest"
}

# --- open -------------------------------------------------------------------

cmd_open() {
  local pid relaunch=0 aid binding meta
  pid="${1:-}"; need_programme "$pid"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --relaunch) relaunch=1 ;;
      *) die "unknown open option: $1" ;;
    esac
    shift
  done

  binding=$(fm_assistance_binding_path "$FM_HOME" "$pid")
  [ -f "$binding" ] || cmd_bind "$pid" >/dev/null

  aid=$(fm_assistance_task_id "$pid")
  meta=$(fm_assistance_meta_path "$FM_HOME" "$aid")

  if [ -f "$meta" ] && [ "$relaunch" -eq 0 ]; then
    cmd_reload "$pid"
    printf 'resumed %s parent=%s\n' "$aid" "$pid"
    return 0
  fi

  if [ -f "$meta" ]; then
    FM_HOME="$FM_HOME" "$FM_SPAWN" "$aid" --relaunch \
      --harness "$FM_ASSISTANCE_HARNESS" --model "$FM_ASSISTANCE_MODEL" --effort "$FM_ASSISTANCE_EFFORT" \
      || die "relaunch of $aid failed; the recorded session was preserved"
    printf 'relaunched %s parent=%s\n' "$aid" "$pid"
    return 0
  fi

  FM_HOME="$FM_HOME" "$FM_SPAWN" "$aid" --supervisor \
    --harness "$FM_ASSISTANCE_HARNESS" --model "$FM_ASSISTANCE_MODEL" --effort "$FM_ASSISTANCE_EFFORT" \
    || die "spawn of $aid failed"
  printf 'opened %s parent=%s harness=%s model=%s effort=%s\n' \
    "$aid" "$pid" "$FM_ASSISTANCE_HARNESS" "$FM_ASSISTANCE_MODEL" "$FM_ASSISTANCE_EFFORT"
}

# --- observe ----------------------------------------------------------------

cmd_observe() {
  local pid limit=20 until="" binding history cursor_file cursor
  pid="${1:-}"; need_programme "$pid"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?--limit needs a count}"; shift ;;
      --replay-until) until="${2:?--replay-until needs a record uuid}"; shift ;;
      *) die "unknown observe option: $1" ;;
    esac
    shift
  done

  binding=$(require_binding "$pid")
  history=$(binding_get "$binding" parent_history)
  [ -f "$history" ] || die "recorded parent history is gone: $history"

  cursor_file=$(fm_assistance_cursor_path "$FM_HOME" "$pid")
  cursor=0
  if [ -z "$until" ] && [ -f "$cursor_file" ]; then
    cursor=$(cat "$cursor_file")
  fi

  local out next
  out=$(FM_A_HISTORY="$history" FM_A_CURSOR="$cursor" FM_A_LIMIT="$limit" FM_A_UNTIL="$until" \
    python3 "$SCRIPT_DIR/fm-assistance-turns.py") || exit 1

  next=$(printf '%s\n' "$out" | sed -n 's/^#next=//p')
  printf '%s\n' "$out" | grep -v '^#next=' || true

  if [ -z "$until" ] && [ -n "$next" ]; then
    printf '%s\n' "$next" > "$cursor_file"
  fi
}

# --- remind -----------------------------------------------------------------

cmd_remind() {
  local pid wid="" action="" evidence="" text binding parent sent fp
  pid="${1:-}"; need_programme "$pid"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) wid="${2:?--id needs a watch id}"; shift ;;
      --action) action="${2:?--action needs the visible action}"; shift ;;
      --evidence) evidence="${2:?--evidence needs the evidence identity}"; shift ;;
      --) shift; break ;;
      -*) die "unknown remind option: $1" ;;
      *) break ;;
    esac
    shift
  done
  text="$*"

  [ -n "$wid" ] || die "name the watch id with --id"
  [ -n "$action" ] || die "name the visible action with --action"
  [ -n "$evidence" ] || die "name the evidence identity with --evidence"
  [ -n "$text" ] || die "the reminder text is empty"
  fm_assistance_form_ok "$text" \
    || die "a reminder must open with one of: $FM_ASSISTANCE_FORMS; assistance delivers awareness, never a decision, gate, or command"

  binding=$(require_binding "$pid")
  parent=$(binding_get "$binding" parent_task_id)
  sent=$(fm_assistance_sent_path "$FM_HOME" "$pid")
  fp=$(fm_assistance_fingerprint "$wid" "$action" "$evidence")

  if [ -f "$sent" ] && grep -qx "$fp" "$sent"; then
    printf 'suppressed %s fingerprint=%s\n' "$wid" "$fp"
    return 0
  fi

  FM_HOME="$FM_HOME" "$FM_SEND" "$parent" "$text" || die "delivery to $parent failed; fingerprint $fp stays unrecorded so the reminder can be retried"
  printf '%s\n' "$fp" >> "$sent"
  printf 'delivered %s to=%s fingerprint=%s\n' "$wid" "$parent" "$fp"
}

# --- lifecycle --------------------------------------------------------------

cmd_lifecycle() {
  local pid state status
  pid="${1:-}"; need_programme "$pid"
  status="$FM_HOME/state/$pid.status"
  state=$(fm_assistance_parent_state "$status")
  if [ "$state" = "terminal" ]; then
    printf 'terminal %s; the programme recorded an explicit terminal result\n' "$pid"
  else
    printf 'live %s; assistance stays active through pause, waiting, and quiet stretches\n' "$pid"
  fi
}

# --- reload -----------------------------------------------------------------

cmd_reload() {
  local pid binding aid digest recorded
  pid="${1:-}"; need_programme "$pid"
  binding=$(require_binding "$pid")
  aid=$(binding_get "$binding" assistance_task_id)
  digest=$(fm_assistance_skill_digest "$SKILL_PATH") || die "assistance skill missing at $SKILL_PATH"
  recorded=$(binding_get "$binding" skill_digest)

  FM_HOME="$FM_HOME" "$FM_SEND" "$aid" \
    "Reread $SKILL_PATH (revision $digest) and apply that exact revision from now on." \
    || die "could not reach $aid to reload the skill revision"

  sed -i "s/^skill_digest=.*/skill_digest=$digest/" "$binding"
  printf 'reloaded %s revision=%s previous=%s\n' "$aid" "$digest" "${recorded:-none}"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  bind) shift; cmd_bind "$@" ;;
  open) shift; cmd_open "$@" ;;
  observe) shift; cmd_observe "$@" ;;
  remind) shift; cmd_remind "$@" ;;
  lifecycle) shift; cmd_lifecycle "$@" ;;
  reload) shift; cmd_reload "$@" ;;
  -h|--help|help) usage ;;
  "") usage; exit 1 ;;
  *) die "unknown command: $1" ;;
esac
