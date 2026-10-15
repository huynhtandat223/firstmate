#!/usr/bin/env bash
# Assistance authority checks shared by public fleet mutation commands.
# Check both cwd and FM_HOME so a caller cannot accidentally escape its home by
# pointing FM_HOME at the parent. This is a role boundary, not an OS sandbox.
fm_assistance_require_dispatcher() {
  local path
  for path in "${FM_HOME:-}" "$PWD"; do
    [ -n "$path" ] && [ -d "$path" ] || continue
    path=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
    while [ "$path" != / ] && [ -n "$path" ]; do
      if [ -e "$path/.fm-assistance-home" ]; then
        echo 'error: assistance rule: observe and propose only; spawning and steering are refused' >&2
        return 1
      fi
      path=${path%/*}
    done
  done
}

fm_assistance_require_ordinary_target() {
  local meta=$1
  if [ -f "$meta" ] && grep -qx 'kind=assistance' "$meta"; then
    if [[ "${2:-}" =~ [^[:space:]] ]]; then return 0; fi
    echo 'error: assistance rule: ordinary worker commands cannot control an assistance; use fm-assistance.sh for an owner-authorized operation' >&2
    return 1
  fi
}

# Claude settings keys that run a command or load executable code, from the
# vendor's settings reference (code.claude.com/docs/en/settings-reference).
FM_ASSISTANCE_COMMAND_KEYS='["hooks","statusLine","subagentStatusLine","apiKeyHelper","awsAuthRefresh","awsCredentialExport","gcpAuthRefresh","otelHeadersHelper","fileSuggestion","enabledPlugins","extraKnownMarketplaces","enableAllProjectMcpServers","enabledMcpjsonServers"]'

# Prints the first reason a profile `workdir` is unusable and returns 1, or
# prints nothing and returns 0. fm-assistance.sh validates with it and
# fm-spawn.sh and fm-claude-trust.sh re-check with it before using the path.
# The workdir is a project the assistance only reads, so it must be a real
# directory outside every firstmate home, and its project Claude settings may
# not define a key that runs a command, because the launch loads them. Each refusal is its own single-line
# guard so a test can remove exactly one and see it go red.
fm_assistance_workdir_error() {  # <path>
  local path=${1:-} real dir home guard_root file key
  case "$path" in
    /*) ;;
    *) echo 'workdir must be an absolute path'; return 1 ;;
  esac
  if [[ "$path" == */ || "$path" == *//* || "$path" =~ (^|/)\.\.?(/|$) || "$path" == *[[:cntrl:]]* ]]; then
    echo 'workdir must be a normalized path'
    return 1
  fi
  [ ! -L "$path" ] || { echo 'workdir must not be a symlink'; return 1; }
  real=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || { echo 'workdir is not an accessible directory'; return 1; }
  guard_root=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  for home in "${FM_HOME:-}" "$guard_root"; do
    [ -n "$home" ] && [ -d "$home" ] || continue
    home=$(CDPATH='' cd -P -- "$home" && pwd -P) || continue
    case "$real" in
      "$home" | "$home"/*) echo 'workdir must not be inside a firstmate home'; return 1 ;;
    esac
  done
  dir=$real
  while [ -n "$dir" ]; do
    [ ! -e "$dir/.fm-assistance-home" ] || { echo 'workdir must not be inside an assistance home'; return 1; }
    [ ! -e "$dir/.fm-secondmate-home" ] || { echo 'workdir must not be inside a secondmate home'; return 1; }
    { [ ! -f "$dir/AGENTS.md" ] || [ ! -f "$dir/bin/fm-spawn.sh" ]; } || { echo 'workdir must not be inside a firstmate checkout'; return 1; }
    dir=${dir%/*}
  done
  for file in settings.json settings.local.json; do
    [ -e "$real/.claude/$file" ] || continue
    key=$(jq -r --argjson keys "$FM_ASSISTANCE_COMMAND_KEYS" 'if type == "object" then . as $s | [$keys[] | select($s[.] != null and $s[.] != {} and $s[.] != [] and $s[.] != "" and $s[.] != false)] | first // "" else error("not an object") end' "$real/.claude/$file" 2>/dev/null) || { echo "workdir's .claude/$file cannot be read as a JSON object, so it cannot be shown free of command-running keys"; return 1; }
    [ -z "$key" ] || { echo "workdir's .claude/$file defines command-running key '$key'"; return 1; }
  done
}
