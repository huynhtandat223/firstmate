#!/usr/bin/env bash
# fm-supervisor-lib.sh - the single owner of the TEMPORARY SUPERVISOR lifecycle.
#
# A temporary supervisor is one bounded direct report whose worktree IS its own
# firstmate home: it holds its own state/, data/, config/, session lock, and
# supervision cycle, it dispatches and supervises ordinary workers of its own,
# and it closes when its one authorized programme finishes. It is NOT a
# secondmate: there is no registry entry, no charter, no inherited local
# material, and no automatic liveness sweep. The parent firstmate manages
# exactly one report - the supervisor - and never reconstructs its child tree.
#
# WHY THIS FILE EXISTS AS A SEPARATE LIBRARY
# Every rule, identity, path, and refusal for that lifecycle lives here, so the
# feature's footprint in the rest of bin/ is a handful of one-line delegations.
# `grep -rn fm_supervisor bin/` lists that complete footprint: to remove the
# feature, delete this file and those call sites; to carry it across an upstream
# upgrade, re-apply those call sites and leave this file untouched.
#
# It defines functions only and has no side effects on source. It is `set -u`
# and `set -e` safe.
#
# The identity marker itself - FM_SUPERVISOR_HOME_MARKER, fm_supervisor_home_id,
# fm_supervisor_home_is_marked - lives in bin/fm-primary-scope-lib.sh, because
# hooks need to recognise a supervisor home while carrying that one dependency-
# free file and nothing else. The marker is excluded per worktree rather than
# through the tracked .gitignore, so it never appears as untracked work.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-primary-scope-lib.sh"

# Lease-holder label recorded with the durable treehouse lease that keeps a
# supervisor home alive with no process inside it.
fm_supervisor_lease_holder() {  # <id>
  printf 'supervisor-%s\n' "$1"
}

# 0 when a direct report of this recorded kind runs its OWN firstmate session in
# its own home, and is therefore supervised through the status writes it sends
# its parent rather than through its pane - an idle agent pane is its healthy
# resting state while its own children do the work.
#
# `secondmate` is included so every call site that already carved secondmates
# out for exactly this reason keeps its behavior byte-for-byte and only has to
# name the shared reason once.
fm_supervisor_kind_self_supervising() {  # <kind>
  case "$1" in
    secondmate|supervisor) return 0 ;;
  esac
  return 1
}

# --- home identity and isolation -------------------------------------------

_fm_supervisor_abs_dir() {  # <path>
  [ -n "$1" ] || return 1
  [ -d "$1" ] || return 1
  ( CDPATH='' cd -- "$1" && pwd -P )
}

_fm_supervisor_is_ancestor_of() {  # <ancestor> <path>
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] || return 1
  case "$2" in
    "$1"/*) return 0 ;;
  esac
  return 1
}

# Refuse anything that is not a genuinely isolated firstmate copy for <id>.
# Every failure prints one actionable line and returns 1; success prints the
# canonical home path. This is the assertion a spawn and a teardown both run
# before they touch the home, so neither can act on the primary checkout, the
# parent home, or another supervisor's home.
fm_supervisor_home_assert() {  # <home> <id> <fm-root> <fm-home>
  local home=$1 id=$2 root=$3 parent=$4 abs abs_root abs_parent top marker_id
  abs=$(_fm_supervisor_abs_dir "$home") || {
    echo "error: supervisor home does not exist or is not a directory: $home" >&2
    return 1
  }
  abs_root=$(_fm_supervisor_abs_dir "$root") || {
    echo "error: firstmate repo root cannot be resolved: $root" >&2
    return 1
  }
  abs_parent=$(_fm_supervisor_abs_dir "$parent") || abs_parent=
  if [ "$abs" = / ] || [ "$abs" = "$abs_root" ] || [ "$abs" = "$abs_parent" ]; then
    echo "error: supervisor home cannot be the firstmate repo or the parent home: $home" >&2
    return 1
  fi
  if _fm_supervisor_is_ancestor_of "$abs_root" "$abs" \
    || _fm_supervisor_is_ancestor_of "$abs" "$abs_root" \
    || { [ -n "$abs_parent" ] && { _fm_supervisor_is_ancestor_of "$abs_parent" "$abs" \
      || _fm_supervisor_is_ancestor_of "$abs" "$abs_parent"; }; }; then
    echo "error: supervisor home overlaps the firstmate repo or the parent home: $home" >&2
    return 1
  fi
  top=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null) || top=
  top=$(_fm_supervisor_abs_dir "$top") || top=
  if [ "$top" != "$abs" ]; then
    echo "error: supervisor home is not the root of its own git worktree: $home" >&2
    return 1
  fi
  if [ ! -f "$abs/AGENTS.md" ] || [ ! -d "$abs/bin" ]; then
    echo "error: supervisor home is not a firstmate copy (missing AGENTS.md or bin): $home" >&2
    return 1
  fi
  marker_id=$(fm_supervisor_home_id "$abs") || {
    echo "error: supervisor home carries no valid $FM_SUPERVISOR_HOME_MARKER identity marker: $home" >&2
    return 1
  }
  if [ "$marker_id" != "$id" ]; then
    echo "error: supervisor home $home is marked for $marker_id, expected $id" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# --- acquisition and release ------------------------------------------------

# Keep the identity marker out of git's view for this worktree only, the same
# mechanism spawn already uses for its worktree-resident hook tokens. Nothing
# tracked changes, so the marker can never show up as uncommitted work and can
# never block a cleanup safety check.
_fm_supervisor_home_exclude_marker() {  # <home>
  local home=$1 excl
  excl=$(git -C "$home" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  [ -n "$excl" ] || return 0
  case "$excl" in
    /*) ;;
    *) excl="$home/$excl" ;;
  esac
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  grep -qxF "$FM_SUPERVISOR_HOME_MARKER" "$excl" 2>/dev/null \
    || printf '%s\n' "$FM_SUPERVISOR_HOME_MARKER" >> "$excl"
}

# Durably lease one isolated firstmate worktree as <id>'s supervisor home and
# print its canonical path. The LEASE is the whole point: a leased worktree is
# never handed to another `treehouse get` and never pruned, so the home - and
# with it the supervisor's own record of its children - survives a dead agent
# and is still there for the relaunch. No product project is cloned into it.
fm_supervisor_home_acquire() {  # <fm-root> <id> <fm-home>
  local root=$1 id=$2 parent=$3 home abs existing
  command -v treehouse >/dev/null 2>&1 || {
    echo "error: treehouse is required to lease a temporary supervisor home for $id" >&2
    return 1
  }
  home=$( CDPATH='' cd -- "$root" && treehouse get --lease --lease-holder "$(fm_supervisor_lease_holder "$id")" ) || {
    echo "error: treehouse get --lease could not lease a supervisor home for $id" >&2
    return 1
  }
  [ -n "$home" ] || {
    echo "error: treehouse get --lease reported no supervisor home for $id" >&2
    return 1
  }
  abs=$(_fm_supervisor_abs_dir "$home") || {
    echo "error: leased supervisor home does not exist: $home" >&2
    return 1
  }
  # A pool worktree that still carries someone else's identity is a state this
  # code cannot reconcile, so it refuses instead of overwriting the marker.
  if existing=$(fm_supervisor_home_id "$abs"); then
    if [ "$existing" != "$id" ]; then
      echo "error: leased worktree $abs already carries supervisor identity $existing; refusing to reuse it for $id" >&2
      return 1
    fi
  elif [ -e "$abs/$FM_SUPERVISOR_HOME_MARKER" ] || [ -L "$abs/$FM_SUPERVISOR_HOME_MARKER" ]; then
    echo "error: leased worktree $abs carries an unreadable $FM_SUPERVISOR_HOME_MARKER marker; refusing to reuse it for $id" >&2
    return 1
  fi
  printf '%s\n' "$id" > "$abs/$FM_SUPERVISOR_HOME_MARKER" || {
    echo "error: could not write the supervisor identity marker in $abs" >&2
    return 1
  }
  _fm_supervisor_home_exclude_marker "$abs"
  fm_supervisor_home_assert "$abs" "$id" "$root" "$parent" >/dev/null || return 1
  printf '%s\n' "$abs"
}

# Give a freshly leased home back after a launch aborts, so a failed spawn never
# leaks a lease that no later `treehouse get` may reuse. Best effort and loud:
# only ever called for a home THIS invocation just leased and never launched.
fm_supervisor_home_release() {  # <fm-root> <home>
  local root=$1 home=$2
  [ -n "$home" ] && [ -d "$home" ] || return 0
  command -v treehouse >/dev/null 2>&1 || {
    echo "warning: treehouse is unavailable; the supervisor home lease at $home is still held" >&2
    return 1
  }
  ( CDPATH='' cd -- "$root" && treehouse return --force "$home" >/dev/null 2>&1 ) || {
    echo "warning: could not return the supervisor home lease at $home; it is still held" >&2
    return 1
  }
}

# --- relaunch ---------------------------------------------------------------

# Print the home already recorded for <id>, or nothing when this is a first
# launch. A stopped supervisor must come back to the SAME home, because that
# home holds its own child inventory: leasing a second one would let it
# re-dispatch workers that already exist. Anything inconsistent refuses rather
# than silently starting over, so a missing home is a stop-and-investigate
# result instead of a duplicate fleet.
fm_supervisor_recorded_home() {  # <meta> <id>
  local meta=$1 id=$2 kind home
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  if [ "$kind" != supervisor ]; then
    echo "error: task $id already has metadata recorded as kind=${kind:-ship}; refusing to reuse that id for a temporary supervisor" >&2
    return 1
  fi
  home=$(sed -n 's/^home=//p' "$meta" | tail -1)
  if [ -z "$home" ]; then
    echo "error: supervisor $id records no home=; repair or tear that record down before relaunching" >&2
    return 1
  fi
  if [ ! -d "$home" ]; then
    echo "error: the home recorded for supervisor $id is gone: $home" >&2
    echo "Its child inventory lived there. Investigate before relaunching; bin/fm-teardown.sh $id --force retires the record once the captain approves discarding it." >&2
    return 1
  fi
  printf '%s\n' "$home"
}
