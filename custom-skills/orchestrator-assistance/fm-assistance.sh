#!/usr/bin/env bash
# fm-assistance.sh - bind, open, and run one read-only assistance companion for
# one live programme supervisor.
#
# Usage:
#   fm-assistance.sh bind <programme-id> [--session <uuid> | --history <path>]
#   fm-assistance.sh bind --primary [--session <uuid>]
#   fm-assistance.sh open <programme-id> [--relaunch] [--session <uuid>]
#   fm-assistance.sh rotate <programme-id> [--handoff <path>]
#   fm-assistance.sh observe <programme-id> [--limit N] [--replay-until <uuid>]
#   fm-assistance.sh remind <programme-id> [--turn <uuid>] --id <watch-id>
#                    --action <action> --evidence <identity> <text...>
#   fm-assistance.sh settle <programme-id> --turn <uuid>
#                    --outcome delivered|suppressed --cue <cue>
#                    --evidence <identity> --reason <reason>
#                    [--delivery <fingerprint>]
#   fm-assistance.sh lifecycle <programme-id>
#   fm-assistance.sh reload <programme-id>
#
# `settle` is the public crash-recovery boundary. A pending turn is not
# consumed merely because `observe` printed it; every turn needs one outcome.
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
# `bind --primary` instead binds the assistance companion to this firstmate home.
# Its Pi session identity is mandatory and is matched against the exact session
# header and home path; no primary endpoint or transcript is selected by recency.
# Everything after it reads that binding, so no later step re-guesses a parent.
#
# One worktree can hold several recorded sessions, and a supervisor's metadata
# carries no session identity, so bind never picks by recency: "newest" is not
# an identity, and a later write to any other session in that directory would
# move the binding to a transcript that is not the parent's. With one candidate
# it binds; with several it refuses and lists them until --session or --history
# names one. The resolved absolute path is then recorded, so the binding stays
# on that transcript no matter what is written afterwards.
#
# ONE SESSION
# `open` is idempotent on the record: a programme whose assistance task is
# already recorded resumes it and reloads the current skill revision instead of
# spawning a second one. `--relaunch` is the explicit path for a recorded
# session whose process is gone; it returns to the same recorded home.
#
# OBSERVATION
# `observe` is two-phase. It records a pending batch and does not advance the
# committed cursor until every emitted turn has a durable delivered/suppressed
# outcome. A later invocation re-emits unsettled turns for recovery.
# `--replay-until <uuid>` instead reads from the start and stops BEFORE that
# record, without touching live sidecars, so replaying history can never carry
# a later correction back into the input that is supposed to precede it.
#
# ROTATION
# `rotate` asks the live companion to write only its judgement to a temporary
# handoff, waits for that file, stops it through fm-control.sh, points the
# relaunch brief at the handoff, and opens a fresh session. Cursor, binding,
# outcomes, and delivery records remain the durable sidecars; a pending batch
# refuses rotation because its turns still need outcomes.
#
# DELIVERY
# `remind` sends one line to the exact parent task, and only in one of the forms
# in FM_ASSISTANCE_FORMS. It never passes --resolve-key, so assistance cannot
# close a parent decision. A repeat of an unchanged fingerprint is suppressed
# without delivery, and a fingerprint is recorded only after delivery succeeds,
# so a failed send stays retryable. When `--turn` is supplied, a successful send
# also records an exact-parent delivery fingerprint for `settle`.
#
# SETTLEMENT
# `settle` accepts one pending turn exactly once as delivered or suppressed.
# It writes the outcome before reconciling the committed cursor, which advances
# only through the longest contiguous settled prefix. Delivered outcomes require
# a matching successful `remind --turn` record; suppression never sends.
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
FM_CONTROL="${FM_CONTROL:-$FM_ROOT/bin/fm-control.sh}"
SKILL_PATH="$SCRIPT_DIR/SKILL.md"
HANDOFF_WAIT="${FM_ASSISTANCE_HANDOFF_WAIT:-30}"
HANDOFF_POLL="${FM_ASSISTANCE_HANDOFF_POLL:-0.2}"

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
  local pid pin="" parent_meta kind worktree history binding digest rc primary=0 primary_harness
  if [ "${1:-}" = --primary ]; then
    primary=1
    pid="primary"
    shift
  else
    pid="${1:-}"; need_programme "$pid"; shift || true
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --primary) [ "$primary" -eq 0 ] || die "--primary was supplied twice"; primary=1; pid=primary ;;
      --session|--history) pin="${2:?$1 needs a session id or history path}"; shift ;;
      *) die "unknown bind option: $1" ;;
    esac
    shift
  done

  if [ "$primary" -eq 1 ]; then
    [ -n "$pin" ] || die "primary bind requires --session <uuid>"
    primary_harness=$(fm_assistance_primary_harness)
    worktree=$FM_HOME
    set +e
    history=$(fm_assistance_primary_history_file "$worktree" "$pin")
    rc=$?
    set -e
    if [ "$rc" -eq 3 ]; then
      die "no readable primary session history for session $pin on harness $(fm_assistance_primary_harness); its history store and matcher are unmeasured, so record them in bin/fm-harness.sh"
    fi
    [ "$rc" -eq 0 ] || die "no readable primary session history for session $pin on harness $(fm_assistance_primary_harness) under $(fm_assistance_primary_history_root)"
  else
    parent_meta=$(fm_assistance_meta_path "$FM_HOME" "$pid")
    [ -f "$parent_meta" ] || die "no supervisor record for $pid at $parent_meta"
    kind=$(fm_assistance_meta_field "$parent_meta" kind)
    [ "$kind" = "supervisor" ] || die "$pid is recorded as kind=${kind:-none}; assistance binds only to a programme supervisor"
    worktree=$(fm_assistance_meta_field "$parent_meta" worktree)
    [ -n "$worktree" ] || die "$pid records no worktree, so its session history cannot be resolved"
    set +e
    history=$(fm_assistance_history_file "$worktree" "$pin")
    rc=$?
    set -e
  fi
  if [ "$rc" -eq 2 ]; then
    printf 'fm-assistance: %s has more than one recorded session history and no session identity to choose by.\n' "$pid" >&2
    printf 'Name the parent session with --session <uuid> or --history <path>. Candidates:\n' >&2
    fm_assistance_history_candidates "$worktree" >&2
    exit 1
  fi
  if [ "$primary" -eq 0 ]; then
    [ "$rc" -eq 0 ] \
      || die "no readable session history for $pid${pin:+ matching $pin} under $(fm_assistance_history_root)/$(fm_assistance_history_dir_name "$worktree"); assistance needs that observable source"
  fi

  digest=$(fm_assistance_skill_digest "$SKILL_PATH") || die "assistance skill missing at $SKILL_PATH"

  binding=$(fm_assistance_binding_path "$FM_HOME" "$pid")
  mkdir -p "$(dirname "$binding")"
  {
    printf 'programme_id=%s\n' "$pid"
    printf 'parent_task_id=%s\n' "$pid"
    printf 'assistance_task_id=%s\n' "$(fm_assistance_task_id "$pid")"
    printf 'parent_worktree=%s\n' "$worktree"
    printf 'parent_history=%s\n' "$history"
    [ "$primary" -eq 0 ] || printf 'primary_harness=%s\n' "$primary_harness"
    printf 'skill_path=%s\n' "$SKILL_PATH"
    printf 'skill_digest=%s\n' "$digest"
    printf 'bound_at=%s\n' "$(date -Iseconds)"
  } > "$binding"

  printf 'bound %s parent=%s history=%s skill=%s\n' \
    "$(fm_assistance_task_id "$pid")" "$pid" "$history" "$digest"
}

# --- open -------------------------------------------------------------------

cmd_open() {
  local pid relaunch=0 pin="" aid binding meta
  pid="${1:-}"; need_programme "$pid"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --relaunch) relaunch=1 ;;
      --session|--history) pin="${2:?$1 needs a session id or history path}"; shift ;;
      *) die "unknown open option: $1" ;;
    esac
    shift
  done

  binding=$(fm_assistance_binding_path "$FM_HOME" "$pid")
  if [ ! -f "$binding" ]; then
    if [ -n "$pin" ]; then
      cmd_bind "$pid" --session "$pin" >/dev/null
    else
      cmd_bind "$pid" >/dev/null
    fi
  fi

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

# --- rotate -----------------------------------------------------------------

handoff_path_for() {  # <programme-id> [requested-path]
  local pid=$1 requested=${2:-}
  if [ -n "$requested" ]; then
    printf '%s\n' "$requested"
  else
    printf '%s/fm-assistance-%s-handoff-%s.md\n' "${TMPDIR:-/tmp}" "$pid" "$(date +%s).$$"
  fi
}

prepare_handoff_brief() {  # <programme-id> <handoff-path>
  local pid=$1 handoff=$2 aid brief marker tmp
  aid=$(fm_assistance_task_id "$pid")
  brief="$FM_HOME/data/$aid/brief.md"
  marker='## Rotation handoff'
  mkdir -p "$(dirname "$brief")"
  tmp="$brief.tmp.$$"
  if [ -f "$brief" ]; then
    awk -v marker="$marker" '
      $0 == marker { skip=1; next }
      skip && /^## / { skip=0 }
      !skip { print }
    ' "$brief" > "$tmp"
  else
    : > "$tmp"
  fi
  {
    printf '%s\n\n' "$marker"
    printf "Before any other work, read the handoff at \`%s\` with your first tool call.\n" "$handoff"
    printf 'The handoff carries judgement only; the durable assistance sidecars remain authoritative.\n\n'
    cat "$tmp"
  } > "$brief.new"
  mv -f "$brief.new" "$brief"
  rm -f "$tmp"
}

cmd_rotate() {
  local pid binding aid pending turns requested handoff start cursor_file
  local parent_history parent_worktree usage used capacity percent target_info backend target new_history new_session primary_harness
  pid="${1:-}"; need_programme "$pid"; shift || true
  requested=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff) requested="${2:?--handoff needs a path}"; shift ;;
      *) die "unknown rotate option: $1" ;;
    esac
    shift
  done
  binding=$(fm_assistance_binding_path "$FM_HOME" primary)
  [ -f "$binding" ] || die "no assistance binding for primary; run: fm-assistance.sh bind --primary --session <uuid>"
  [ "$(binding_get "$binding" programme_id)" = primary ] || die "rotate only targets the bound primary"
  primary_harness=$(binding_get "$binding" primary_harness)
  [ -n "$primary_harness" ] || die "primary binding records no harness; rebind the primary before rotation"
  export FM_ASSISTANCE_PRIMARY_HARNESS="$primary_harness" FM_DAEMON_PRIMARY_HARNESS="$primary_harness"
  aid=$(binding_get "$binding" assistance_task_id)
  parent_history=$(binding_get "$binding" parent_history)
  parent_worktree=$(binding_get "$binding" parent_worktree)
  pending=$(fm_assistance_pending_path "$FM_HOME" "$pid")
  if [ -f "$pending" ]; then
    turns=$(awk -F '\t' '$1 ~ /^turn=/ {printf "%s%s", sep, $3; sep=", "}' "$pending")
    die "cannot rotate while the pending observation batch is unsettled; settle is the crash-recovery boundary: ${turns:-unknown}"
  fi
  usage=$(fm_assistance_context_usage "$parent_history") || die "cannot measure primary context usage from $parent_history; rotation refuses rather than silently never firing"
  IFS=$'\t' read -r used capacity percent <<<"$usage"
  [ "${percent%.*}" -ge 60 ] || { printf 'below rotation threshold: usage=%s/%s (%.2f%%), threshold=60%%\n' "$used" "$capacity" "$percent"; return 0; }
  handoff=$(handoff_path_for "$pid" "$requested")
  [ ! -e "$handoff" ] || die "handoff path already exists: $handoff"
  mkdir -p "$(dirname "$handoff")"
  cursor_file=$(fm_assistance_cursor_path "$FM_HOME" "$pid")
  . "$FM_ROOT/bin/fm-primary-inject.sh"
  target_info=$(fm_primary_target_from_home "$FM_HOME") || die "cannot resolve the bound primary endpoint"
  IFS=$'\t' read -r backend target <<EOF
$target_info
EOF
  fm_primary_inject assistance "$backend" "$target" \
    "Use /handoff now. Write the judgement-only handoff for this primary to $handoff. Do not copy durable sidecars." \
    || die "could not ask the bound primary for a handoff"
  start=$SECONDS
  while [ ! -f "$handoff" ]; do
    [ "$((SECONDS - start))" -lt "$HANDOFF_WAIT" ] || die "handoff did not appear at $handoff within ${HANDOFF_WAIT}s"
    sleep "$HANDOFF_POLL"
  done
  fm_primary_rotate "$backend" "$target" "$handoff" || die "primary rotation was not confirmed"
  start=$SECONDS
  while [ "$((SECONDS - start))" -lt "$HANDOFF_WAIT" ]; do
    new_history=$(fm_assistance_primary_history_replacement "$parent_worktree" "$parent_history" 2>/dev/null || true)
    [ -n "$new_history" ] && break
    sleep "$HANDOFF_POLL"
  done
  [ -n "$new_history" ] || new_history=$parent_history
  new_session=$(fm_assistance_primary_session_id "$new_history")
  sed -i "s|^parent_history=.*|parent_history=$new_history|" "$binding"
  printf 'primary_session=%s\n' "$new_session" >> "$binding"
  rm -f "$cursor_file"
  printf 'rotation_handoff=%s usage_before=%s/%s (%.2f%%) committed_cursor=reset replacement_history=%s new_endpoint=%s\n' "$handoff" "$used" "$capacity" "$percent" "$new_history" "${target:-unknown}"
}

# --- observe ----------------------------------------------------------------

pending_emit() {  # <pending-file>
  sed -n 's/^turn=//p' "$1"
}

pending_has_turn() {  # <pending-file> <turn-id>
  awk -F '\t' -v wanted="$2" '$1 ~ /^turn=/ && $3 == wanted {found=1} END {exit(found ? 0 : 1)}' "$1"
}

fields_ok() {  # <value>...
  local value
  for value in "$@"; do
    fm_assistance_field_ok "$value" || return 1
  done
}

outcome_has_turn() {  # <outcomes-file> <turn-id>
  [ -f "$1" ] || return 1
  awk -F '\t' -v wanted="$2" '$1 == "turn=" wanted {found=1} END {exit(found ? 0 : 1)}' "$1"
}

pending_write() {  # <path> <prior> <next> <records>
  local path=$1 prior=$2 next=$3 records=$4 tmp
  [ -n "$records" ] || return 0
  tmp="$path.tmp.$$"
  {
    printf 'prior_cursor=%s\n' "$prior"
    printf 'next_cursor=%s\n' "$next"
    printf '%s\n' "$records" | while IFS= read -r record; do
      [ -n "$record" ] || continue
      printf 'turn=%s\n' "$record"
    done
  } > "$tmp"
  mv -f "$tmp" "$path"
}

reconcile_cursor() {  # <programme-id> <pending-file> <cursor-file> <outcomes-file>
  local pid=$1 pending=$2 cursor_file=$3 outcomes=$4 cursor initial_cursor cursor_was_present line tmp remaining prefix_open
  cursor=0
  cursor_was_present=0
  if [ -f "$cursor_file" ]; then
    cursor=$(cat "$cursor_file")
    cursor_was_present=1
  fi
  initial_cursor=$cursor
  remaining=""
  prefix_open=0
  while IFS=$'\t' read -r marker ptype puuid ptimestamp pexcerpt; do
    case "$marker" in turn=*) ;; *) continue ;; esac
    line=${marker#turn=}
    if [ "$prefix_open" -eq 0 ] && outcome_has_turn "$outcomes" "$puuid"; then
      cursor=$line
    else
      # Once an earlier turn is unsettled, retain every later turn, including
      # already-settled ones, so a later settlement can advance the whole pair.
      prefix_open=1
      remaining+="${marker}"$'\t'"${ptype}"$'\t'"${puuid}"$'\t'"${ptimestamp}"$'\t'"${pexcerpt}"$'\n'
    fi
  done < <(grep '^turn=' "$pending" || true)

  if [ "$cursor" != "$initial_cursor" ] || [ "$cursor_was_present" -eq 1 ]; then
    printf '%s\n' "$cursor" > "$cursor_file"
  else
    rm -f "$cursor_file"
  fi
  if [ "$prefix_open" -eq 0 ]; then
    rm -f "$pending"
  else
    tmp="$pending.tmp.$$"
    {
      printf 'prior_cursor=%s\n' "$cursor"
      sed -n 's/^next_cursor=//p' "$pending" | sed 's/^/next_cursor=/'
      printf '%s' "$remaining" | while IFS= read -r record; do
        [ -n "$record" ] && printf '%s\n' "$record"
      done
    } > "$tmp"
    mv -f "$tmp" "$pending"
  fi
}

cmd_observe() {
  local pid limit=20 until="" binding history cursor_file cursor pending out next records
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
  pending=$(fm_assistance_pending_path "$FM_HOME" "$pid")
  cursor=0
  if [ -z "$until" ] && [ -f "$cursor_file" ]; then
    cursor=$(cat "$cursor_file")
  fi

  # Recovery is deliberately ahead of the history read. A process that died
  # after observe must see the same identities again, not skip to new input.
  if [ -z "$until" ] && [ -f "$pending" ]; then
    # Finish any outcomes durable before a crash, then re-emit only the still
    # unsettled suffix. This is the recovery path for interrupted settlement.
    reconcile_cursor "$pid" "$pending" "$cursor_file" "$(fm_assistance_outcomes_path "$FM_HOME" "$pid")"
    if [ -f "$pending" ]; then
      pending_emit "$pending"
      printf '#pending=1\n'
      return 0
    fi
  fi

  out=$(FM_A_HISTORY="$history" FM_A_CURSOR="$cursor" FM_A_LIMIT="$limit" FM_A_UNTIL="$until" \
    python3 "$SCRIPT_DIR/fm-assistance-turns.py") || exit 1

  next=$(printf '%s\n' "$out" | sed -n 's/^#next=//p')
  records=$(printf '%s\n' "$out" | grep -v '^#next=' || true)
  printf '%s\n' "$records"

  if [ -z "$until" ] && [ -n "$next" ]; then
    if [ -n "$records" ]; then
      mkdir -p "$(dirname "$pending")"
      pending_write "$pending" "$cursor" "$next" "$records"
      printf '#pending=1\n'
    else
      # No observable parent turn needs an outcome, so harmless history records
      # can be consumed without creating a phantom pending batch.
      printf '%s\n' "$next" > "$cursor_file"
    fi
  fi
}

# --- remind -----------------------------------------------------------------

cmd_remind() {
  local pid wid="" action="" evidence="" text binding parent sent deliveries fp turn delivery_fp target_info backend target
  pid="${1:-}"; need_programme "$pid"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --turn) turn="${2:?--turn needs an observed turn id}"; shift ;;
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
  turn=${turn:-}

  [ -n "$wid" ] || die "name the watch id with --id"
  [ -n "$action" ] || die "name the visible action with --action"
  [ -n "$evidence" ] || die "name the evidence identity with --evidence"
  [ -n "$text" ] || die "the reminder text is empty"
  fm_assistance_form_ok "$text" \
    || die "a reminder must open with one of: $FM_ASSISTANCE_FORMS; assistance delivers awareness, never a decision, gate, or command"
  fields_ok "$turn" "$wid" "$action" "$evidence" "$text" \
    || die "reminder fields cannot contain tabs or newlines"

  binding=$(require_binding "$pid")
  parent=$(binding_get "$binding" parent_task_id)
  sent=$(fm_assistance_sent_path "$FM_HOME" "$pid")
  deliveries=$(fm_assistance_deliveries_path "$FM_HOME" "$pid")
  fp=$(fm_assistance_fingerprint "$wid" "$action" "$evidence")

  if [ -f "$sent" ] && grep -qx "$fp" "$sent"; then
    if [ -z "$turn" ]; then
      printf 'suppressed %s fingerprint=%s\n' "$wid" "$fp"
      return 0
    fi
    if [ -f "$deliveries" ]; then
      delivery_fp=$(awk -F '\t' -v wanted_turn="$turn" '$1 == "turn=" wanted_turn {sub(/^delivery=/, "", $2); print $2; exit}' "$deliveries")
      if [ -n "$delivery_fp" ]; then
        printf 'suppressed %s fingerprint=%s delivery=%s\n' "$wid" "$fp" "$delivery_fp"
        return 0
      fi
    fi
  fi

  if [ "$(binding_get "$binding" programme_id)" = primary ]; then
    # shellcheck source=bin/fm-primary-inject.sh
    . "$FM_ROOT/bin/fm-primary-inject.sh"
    target_info=$(fm_primary_target_from_home "$FM_HOME") \
      || die "cannot resolve the live primary endpoint for $FM_HOME"
    IFS=$'\t' read -r backend target <<EOF
$target_info
EOF
    fm_primary_inject assistance "$backend" "$target" "$text" \
      || die "delivery to the primary session was deferred; fingerprint $fp stays unrecorded so the reminder can be retried"
  else
    FM_HOME="$FM_HOME" "$FM_SEND" "$parent" "$text" \
      || die "delivery to $parent failed; fingerprint $fp stays unrecorded so the reminder can be retried"
  fi
  mkdir -p "$(dirname "$sent")"
  printf '%s\n' "$fp" >> "$sent"
  if [ -n "$turn" ]; then
    delivery_fp=$(fm_assistance_delivery_fingerprint "$parent" "$turn" "$fp" "$text")
    printf 'turn=%s\tdelivery=%s\tparent=%s\ttext=%s\n' "$turn" "$delivery_fp" "$parent" "$text" >> "$deliveries"
    printf 'delivered %s to=%s fingerprint=%s delivery=%s\n' "$wid" "$parent" "$fp" "$delivery_fp"
  else
    printf 'delivered %s to=%s fingerprint=%s\n' "$wid" "$parent" "$fp"
  fi
}

# --- settle -----------------------------------------------------------------

cmd_settle() {
  local pid turn="" outcome="" cue="" evidence="" reason="" delivery="" binding pending outcomes deliveries
  pid="${1:-}"; need_programme "$pid"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --turn) turn="${2:?--turn needs an observed turn id}"; shift ;;
      --outcome) outcome="${2:?--outcome needs delivered or suppressed}"; shift ;;
      --cue) cue="${2:?--cue needs the matched cue}"; shift ;;
      --evidence) evidence="${2:?--evidence needs the evidence identity}"; shift ;;
      --reason) reason="${2:?--reason needs the settlement reason}"; shift ;;
      --delivery) delivery="${2:?--delivery needs a send fingerprint}"; shift ;;
      *) die "unknown settle option: $1" ;;
    esac
    shift
  done
  [ -n "$turn" ] || die "name the pending turn with --turn"
  case "$outcome" in delivered|suppressed) ;; *) die "outcome must be delivered or suppressed" ;; esac
  [ -n "$cue" ] || die "name the matched cue with --cue"
  [ -n "$evidence" ] || die "name the evidence identity with --evidence"
  [ -n "$reason" ] || die "name the settlement reason with --reason"
  fields_ok "$turn" "$outcome" "$cue" "$evidence" "$reason" "$delivery" \
    || die "settlement fields cannot contain tabs or newlines"

  binding=$(require_binding "$pid")
  pending=$(fm_assistance_pending_path "$FM_HOME" "$pid")
  outcomes=$(fm_assistance_outcomes_path "$FM_HOME" "$pid")
  deliveries=$(fm_assistance_deliveries_path "$FM_HOME" "$pid")
  if outcome_has_turn "$outcomes" "$turn"; then
    printf 'already-settled turn=%s\n' "$turn"
    return 0
  fi
  [ -f "$pending" ] || die "turn $turn is not pending"
  pending_has_turn "$pending" "$turn" || die "turn $turn is not in the pending batch"

  if [ "$outcome" = delivered ]; then
    [ -n "$delivery" ] || die "delivered settlement needs --delivery from a successful remind --turn"
    parent=$(binding_get "$binding" parent_task_id)
    awk -F '\t' -v wanted_turn="$turn" -v wanted_delivery="$delivery" -v wanted_parent="$parent" \
      '$1 == "turn=" wanted_turn && $2 == "delivery=" wanted_delivery && $3 == "parent=" wanted_parent {found=1} END {exit(found ? 0 : 1)}' "$deliveries" \
      || die "delivery $delivery is not a successful exact-parent send for turn $turn"
  else
    [ -z "$delivery" ] || die "suppressed settlement cannot claim a delivery"
  fi

  mkdir -p "$(dirname "$outcomes")"
  printf 'turn=%s\toutcome=%s\tcue=%s\tevidence=%s\treason=%s\tdelivery=%s\tat=%s\n' \
    "$turn" "$outcome" "$cue" "$evidence" "$reason" "$delivery" "$(date -Iseconds)" >> "$outcomes"
  reconcile_cursor "$pid" "$pending" "$(fm_assistance_cursor_path "$FM_HOME" "$pid")" "$outcomes"
  printf 'settled turn=%s outcome=%s\n' "$turn" "$outcome"
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
  rotate) shift; cmd_rotate "$@" ;;
  observe) shift; cmd_observe "$@" ;;
  remind) shift; cmd_remind "$@" ;;
  settle) shift; cmd_settle "$@" ;;
  lifecycle) shift; cmd_lifecycle "$@" ;;
  reload) shift; cmd_reload "$@" ;;
  -h|--help|help) usage ;;
  "") usage; exit 1 ;;
  *) die "unknown command: $1" ;;
esac
