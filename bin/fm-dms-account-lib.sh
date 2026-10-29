#!/usr/bin/env bash
# DMS account guard (spec huynhtandat223/firstmate#200, E6a).
#
# Captain 2026-10-26: work on the DMS projects, and the dms assistance, runs on
# one Claude account only, because the company watches that account. The map
# lives in config/dms-account, never in code. One entry per line; blank lines
# and # comments are ignored:
#   root <path>          the only Claude config root a DMS launch may use (~ allowed)
#   project <name>       a DMS project, by the basename of its clone
#   assistance <name>    a DMS assistance, by its registry name
# With the file absent the guard does nothing. A file with no root line, or a
# line this parser does not know, refuses: a strict company rule must not pass
# because its file was misspelled.
#
# fm_dms_account_guard <config-dir> <state-dir> <project|assistance> <name> <harness> <claude-root>
#   <claude-root> is the CLAUDE_CONFIG_DIR the launch resolves to; empty means
#   the default ~/.claude. Only a claude launch is checked. On a mismatch it
#   prints the refusal to stderr and returns 1 once config/enforce-dms-account
#   holds `block` (bin/fm-enforce-lib.sh); until then it writes the would-be
#   refusal to state/enforce-dms-account.log and returns 0.

_fm_dms_account_lib_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-enforce-lib.sh
. "$_fm_dms_account_lib_dir/fm-enforce-lib.sh"

# Expand a leading ~ and strip trailing slashes; resolve symlinks when the directory exists.
_fm_dms_account_norm() {  # <path>
  local path=$1
  case "$path" in
    '~') path=$HOME ;;
    \~/*) path="$HOME/${path#\~/}" ;;
  esac
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
  if [ -d "$path" ]; then (CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"; else printf '%s\n' "$path"; fi
}

fm_dms_account_guard() {  # <config-dir> <state-dir> <kind> <name> <harness> <claude-root>
  local config=$1 state=$2 kind=$3 name=$4 harness=$5 resolved=$6
  local file="$config/dms-account" line key value n=0 root='' listed=0 expected
  [ "$harness" = claude ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    key=${line%%[[:space:]]*}
    value=${line#"$key"}
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$key" ] || continue
    case "$key" in
      root) root=$value ;;
      project) [ "$kind" != project ] || [ "$value" != "$name" ] || listed=1 ;;
      assistance) [ "$kind" != assistance ] || [ "$value" != "$name" ] || listed=1 ;;
      *) echo "error: config/dms-account line $n: expected root, project or assistance, got '$key'" >&2; return 1 ;;
    esac
  done < "$file"
  if [ -z "$root" ]; then
    echo "error: config/dms-account has no 'root <path>' line" >&2
    return 1
  fi
  [ "$listed" -eq 1 ] || return 0
  expected=$(_fm_dms_account_norm "$root")
  [ -n "$resolved" ] || resolved="$HOME/.claude"
  [ "$(_fm_dms_account_norm "$resolved")" != "$expected" ] || return 0
  local text="$kind $name is listed in config/dms-account, so Claude must run under $root, but this launch resolves CLAUDE_CONFIG_DIR to $resolved. Launch it with CLAUDE_CONFIG_DIR=$root (or pin config/claude-account to $root)."
  if [ "$(fm_enforce_mode "$config" dms-account)" != block ]; then
    fm_enforce_log "$state" dms-account would-refuse "$kind-$name" "$text"
    return 0
  fi
  fm_enforce_log "$state" dms-account refuse "$kind-$name" "$text"
  echo "error: launch refused: $text" >&2
  return 1
}
