#!/usr/bin/env bash
# Model deny list (spec huynhtandat223/firstmate#200, E6b).
#
# config/model-deny is captain-private: one glob and its reason per line, the
# glob first, then whitespace, then the reason. Blank lines and # comment lines
# are ignored. First entry on the live home:
#   *deepseek-v4-pro*  captain.md:9 DeepSeek is always Flash
# With the file absent nothing changes. A line with a glob but no reason refuses,
# so a hit always says why.
#
# fm_model_deny_guard <config-dir> <state-dir> <model>
#   An empty or `default` model passes. On a match it prints the refusal with
#   the line's reason to stderr and returns 1 once config/enforce-model-deny
#   holds `block` (bin/fm-enforce-lib.sh); until then it writes the would-be
#   refusal to state/enforce-model-deny.log and returns 0.

_fm_model_deny_lib_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-enforce-lib.sh
. "$_fm_model_deny_lib_dir/fm-enforce-lib.sh"

fm_model_deny_guard() {  # <config-dir> <state-dir> <model>
  local config=$1 state=$2 model=$3
  local file="$config/model-deny" line glob reason n=0
  { [ -n "$model" ] && [ "$model" != default ]; } || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|[[:space:]]*'#'*|'#'*) continue ;; esac
    glob=${line%%[[:space:]]*}
    [ -n "$glob" ] || continue
    reason=$(printf '%s' "${line#"$glob"}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$reason" ]; then
      echo "error: config/model-deny line $n: '$glob' has no reason" >&2
      return 1
    fi
    # shellcheck disable=SC2254
    case "$model" in
      $glob)
        if [ "$(fm_enforce_mode "$config" model-deny)" != block ]; then
          fm_enforce_log "$state" model-deny would-refuse "$model" "$reason"
          return 0
        fi
        fm_enforce_log "$state" model-deny refuse "$model" "$reason"
        echo "error: model refused: $model matches $glob in config/model-deny: $reason" >&2
        return 1
        ;;
    esac
  done < "$file"
  return 0
}
