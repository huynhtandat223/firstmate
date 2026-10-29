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
# With the file absent the guard does nothing. A file that exists but cannot be
# read, a file with no root line, or a line this parser does not know, refuses:
# a strict company rule must not pass because its file was misspelled or locked.
#
# fm_dms_account_guard <config-dir> <state-dir> <project|assistance> <name> <harness> <claude-root>
#   <claude-root> is the CLAUDE_CONFIG_DIR the launch resolves to; empty means
#   the default ~/.claude. Only a claude launch is checked. On a mismatch it
#   prints the refusal to stderr and returns 1 once config/enforce-dms-account
#   holds `block` (bin/fm-enforce-lib.sh); until then it writes the would-be
#   refusal to state/enforce-dms-account.log and returns 0.
# fm_dms_account_raw_parse <launch-command>   reads a raw launch command's leading
#   assignments, quote-aware, for the CLAUDE_CONFIG_DIR it sets for itself (which
#   overrides the caller's environment and a pinned account), its first command
#   word and any shed-list credential it assigns.
# fm_dms_account_raw_guard   on a listed launch, a raw command must start with claude
#   and assign no shed-list credential (block mode refuses, log-only logs).
# FM_DMS_ACCOUNT_LISTED is 1 after a guard call when the launch is a listed DMS
#   project or assistance, so the caller can shed other credentials from it.
# fm_dms_account_project_name <project-dir>   prints the clone's basename after
#   resolving the directory canonically, so `/repos/dms-workspaces/.` and a
#   symlink to it name the same project.

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

# Split a launch command into words the way the shell does for quotes and
# backslashes (no expansion), into the array FM_DMS_WORDS.
_fm_dms_account_words() {  # <command>
  local text=$1 i ch word='' inword=0 quote=''
  FM_DMS_WORDS=()
  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    if [ "$quote" = "'" ]; then
      if [ "$ch" = "'" ]; then quote=''; else word+=$ch; fi
    elif [ "$quote" = '"' ]; then
      if [ "$ch" = '"' ]; then quote=''
      elif [ "$ch" = '\' ] && [[ ${text:i+1:1} == [\"\\\$\`] ]]; then i=$((i + 1)); word+=${text:i:1}
      else word+=$ch; fi
    else
      case "$ch" in
        "'" | '"') quote=$ch; inword=1 ;;
        '\') i=$((i + 1)); word+=${text:i:1}; inword=1 ;;
        ' ' | $'\t' | $'\n')
          if [ "$inword" -eq 1 ]; then FM_DMS_WORDS+=("$word"); word=''; inword=0; fi
          ;;
        *) word+=$ch; inword=1 ;;
      esac
    fi
  done
  if [ "$inword" -eq 1 ]; then FM_DMS_WORDS+=("$word"); fi
}

# fm_dms_account_raw_parse <launch-command>
#   Reads a raw launch command through its leading NAME=value words (quote-aware)
#   and sets:
#   FM_DMS_RAW_HARNESS   the basename of the first word that is not an assignment
#   FM_DMS_RAW_ROOT_SET  1 when a leading word assigns CLAUDE_CONFIG_DIR, and
#   FM_DMS_RAW_ROOT      its value; the last such word wins, as in the shell, and
#                        it overrides the caller's environment and a pinned account
#   FM_DMS_RAW_CREDENTIALS  the names of leading assignments on the Claude
#                        credential shed list (FM_WORKER_ACCOUNT_CLAUDE_SHED)
fm_dms_account_raw_parse() {  # <launch-command>
  local word name shed
  FM_DMS_RAW_HARNESS='' FM_DMS_RAW_ROOT='' FM_DMS_RAW_ROOT_SET=0 FM_DMS_RAW_CREDENTIALS=''
  _fm_dms_account_words "$1"
  for word in "${FM_DMS_WORDS[@]}"; do
    case "$word" in
      [A-Za-z_]*=*)
        name=${word%%=*}
        if [ "$name" = CLAUDE_CONFIG_DIR ]; then FM_DMS_RAW_ROOT=${word#*=} FM_DMS_RAW_ROOT_SET=1; fi
        for shed in ${FM_WORKER_ACCOUNT_CLAUDE_SHED:-}; do
          if [ "$name" = "$shed" ]; then FM_DMS_RAW_CREDENTIALS="${FM_DMS_RAW_CREDENTIALS:+$FM_DMS_RAW_CREDENTIALS }$name"; fi
        done
        ;;
      *) FM_DMS_RAW_HARNESS=$(basename -- "$word"); break ;;
    esac
  done
}

# fm_dms_account_raw_guard <config-dir> <state-dir> <kind> <name> <launch-command>
#   Run after fm_dms_account_guard, for a raw launch command on a launch the file
#   lists (FM_DMS_ACCOUNT_LISTED=1). A raw command is not read through wrappers:
#   its first non-assignment word must be claude, and it must assign no
#   credential from the shed list. On a breach it prints the refusal to stderr
#   and returns 1 once config/enforce-dms-account holds `block`; until then it
#   writes the would-be refusal to state/enforce-dms-account.log and returns 0.
fm_dms_account_raw_guard() {  # <config-dir> <state-dir> <kind> <name> <launch-command>
  local config=$1 state=$2 kind=$3 name=$4 problem=''
  [ "${FM_DMS_ACCOUNT_LISTED:-0}" = 1 ] || return 0
  fm_dms_account_raw_parse "$5"
  if [ "$FM_DMS_RAW_HARNESS" != claude ]; then
    problem="its first non-assignment word is '${FM_DMS_RAW_HARNESS:-none}', not claude (a wrapper such as env, command or exec is not read)"
  elif [ -n "$FM_DMS_RAW_CREDENTIALS" ]; then
    problem="it assigns $FM_DMS_RAW_CREDENTIALS, which outranks the root's own login"
  else
    return 0
  fi
  local text="$kind $name is listed in config/dms-account, but the raw launch command is refused: $problem. Launch it as [CLAUDE_CONFIG_DIR=<root>] claude ... with no credential assignment."
  if [ "$(fm_enforce_mode "$config" dms-account)" != block ]; then
    fm_enforce_log "$state" dms-account would-refuse "$kind-$name" "$text"
    return 0
  fi
  fm_enforce_log "$state" dms-account refuse "$kind-$name" "$text"
  echo "error: launch refused: $text" >&2
  return 1
}

fm_dms_account_project_name() {  # <project-dir>
  local dir=$1 canon
  canon=$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P) || canon=$dir
  while [ "${#canon}" -gt 1 ] && [ "${canon%/}" != "$canon" ]; do canon=${canon%/}; done
  basename -- "$canon"
}

fm_dms_account_guard() {  # <config-dir> <state-dir> <kind> <name> <harness> <claude-root>
  local config=$1 state=$2 kind=$3 name=$4 harness=$5 resolved=$6
  local file="$config/dms-account" line key value n=0 root='' listed=0 expected
  FM_DMS_ACCOUNT_LISTED=0
  [ "$harness" = claude ] || return 0
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      echo "error: config/dms-account exists but cannot be read; fix it or remove it" >&2
      return 1
    fi
  else
    return 0
  fi
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
  FM_DMS_ACCOUNT_LISTED=1
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
