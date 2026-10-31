#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# `rows [list flags]` is firstmate's own read: the same `list` table as one JSON
# array of objects (hold reasons decoded, "-" and "none" as null, and the full
# title and body of a row `list` cut, read with `show <id> --full`). Scripts that
# need task fields read the backlog through it rather than parsing a backlog file.
#
# While config/task-shadow is on, a landed `hold` or `start` is followed by
# bin/fm-task-shadow.sh's `held` or `started` lifecycle write; it never changes
# the exit status. The backlog itself is not mirrored: under the cfw5001
# backend tasks-axi writes the Dev 5001 rows and no backlog file.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
#   - `add` (or `create`) of an id that is already a done task, or of a title whose
#     ticket key a live task already carries (bin/fm-task-identity-check.sh; log-only
#     until config/enforce-task-identity holds block);
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

# Task identity check (config/enforce-task-identity, bin/fm-task-identity-check.sh):
# a reused done id, a live second task for one ticket key. Before tasks-axi runs.
case "${1:-}" in
  add|create)
    ti_id=${2:-} ti_title=${3:-} ti_repo='' ti_prev=''
    for arg in "$@"; do
      [ "$ti_prev" != --repo ] || ti_repo=$arg
      case "$arg" in --repo=*) ti_repo=${arg#--repo=} ;; esac
      ti_prev=$arg
    done
    case "$ti_id" in ''|-*) ;; *)
      "$SCRIPT_DIR/fm-task-identity-check.sh" add "$ti_id" "$ti_title" "$ti_repo" || exit 2
    ;; esac
    ;;
esac

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

# Resolve against the caller before changing to the backlog adapter root.
DATA=$(cd "$DATA" && pwd -P) || fail "cannot resolve backlog data directory $DATA"

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  rows)
    # `rows [list flags]`: the `list` table as one JSON array of objects, hold reasons decoded, "-" and "none" as
    # null. `list` cuts a long title or body; for such a row the full text comes from `show <id> --full`, so a
    # reader never sees a cut value. The one structured backlog read for scripts.
    set -o pipefail
    listed=$(tasks-axi list "${ARGS[@]:1}" | fm_hold_reason_decode_stream | jq -Rn '
      def cell: if startswith("\"") then fromjson else . end;
      def cut: test("\n\\.\\.\\. \\(truncated, [0-9]+ chars total");
      reduce inputs as $line ({fields: null, rows: []};
        if ($line | test("^tasks\\[[0-9]+\\]\\{")) then
          .fields = ($line | capture("\\{(?<f>[^}]*)\\}").f | split(","))
        elif .fields != null and ($line | startswith("  ")) then
          .fields as $f
          | ([$line | ltrimstr("  ") | scan("\"(?:[^\"\\\\]|\\\\.)*\"|[^,]+") | cell]) as $c
          | .rows += [reduce range(0; $f | length) as $i ({};
              .[$f[$i]] = ($c[$i] | if . == "-" or (. == "none" and $f[$i] != "title") then null else . end))
              | ._cut = [to_entries[] | select((.value | type) == "string" and (.value | cut)) | .key]]
        else .fields = null end)
      | .rows') || exit $?
    full=
    for cut_id in $(printf '%s' "$listed" | jq -r '.[] | select(._cut | length > 0) | .id'); do
      one=$(tasks-axi show "$cut_id" --full | fm_hold_reason_decode_stream | jq -Rn --arg id "$cut_id" '
        reduce inputs as $l ({};
          if ($l | test("^  (title|body): ")) then
            ($l | capture("^  (?<k>title|body): (?<v>.*)$")) as $m
            | .[$m.k] = ($m.v | if startswith("\"") then fromjson else . end)
          else . end) | {($id): .}' | jq -c .) || exit $?
      full=$full$one$'\n'
    done
    # Through stdin, not argv: a full body can pass the argument size limit.
    printf '%s\n%s' "$listed" "$full" | jq -s '
      .[0] as $rows | (.[1:] | add // {}) as $full
      | $rows | map(. as $r | reduce ($r._cut[]) as $k ($r; .[$k] = ($full[$r.id][$k] // .[$k])) | del(._cut))'
    exit $?
    ;;
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
case "${1:-}" in ''|ready|-*) exec tasks-axi ${ARGS[@]+"${ARGS[@]}"} ;; esac
for arg in "$@"; do case "$arg" in -h|--help) exec tasks-axi ${ARGS[@]+"${ARGS[@]}"} ;; esac; done
tasks-axi ${ARGS[@]+"${ARGS[@]}"} || exit $?
if [ -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/task-shadow" ]; then
  id=${2:-}
  case "$id" in ''|-*) ;; *)
    case "${1:-}" in
      hold)
        kind=hold reason='' previous=''
        for arg in "$@"; do
          case "$previous" in --kind) kind=$arg ;; --reason) reason=$arg ;; esac
          previous=$arg
        done
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task-shadow.sh" held "$id" "$kind" "$reason" >/dev/null 2>&1 || true ;;
      start) FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task-shadow.sh" started "$id" "$(date +%s)-$$-${RANDOM}" >/dev/null 2>&1 || true ;;
    esac
  esac
fi
exit 0
