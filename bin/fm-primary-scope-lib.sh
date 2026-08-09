#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints, has no side effects on source, and
# deliberately depends on nothing else so a hook can carry it alone.
#
# Two kinds of home are linked git worktrees yet still run their own primary
# firstmate session: a persistent secondmate home, and the temporary supervisor
# home bin/fm-supervisor-lib.sh leases for one programme. Each declares itself
# with a gitignored identity marker at its root, and this file owns reading and
# validating those markers. The supervisor lifecycle - lease, relaunch, cleanup
# gates - lives in bin/fm-supervisor-lib.sh, which sources this file.

FM_SUPERVISOR_HOME_MARKER=".fm-supervisor-home"

# Print the identity recorded in <dir>/<marker-filename>, or return 1 when the
# marker is absent, a symlink, empty, or not a privacy-safe slug.
fm_home_marker_id() {  # <dir> <marker-filename>
  local marker="$1/$2" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  fm_home_marker_id "$1" ".fm-secondmate-home" >/dev/null
}

# Print the temporary-supervisor id recorded at $1, or return 1.
fm_supervisor_home_id() {  # <dir>
  fm_home_marker_id "$1" "$FM_SUPERVISOR_HOME_MARKER"
}

# Return 0 when $1 carries a genuine temporary-supervisor-home marker.
fm_supervisor_home_is_marked() {  # <dir>
  fm_supervisor_home_id "$1" >/dev/null
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate or temporary-supervisor marker force-includes that linked
# home. Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root" && ! fm_supervisor_home_is_marked "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}
