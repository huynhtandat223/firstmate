#!/usr/bin/env bash
# Regression test for fm-spawn.sh --agent-path (bin/fm-spawn.sh).
#
# --agent-path narrows where a worker STARTS: the agent is launched in a
# directory inside its own task worktree instead of at the worktree root, so a
# brief scoped to one module puts the agent in that module. The logic under test
# is harness-independent - path resolution against the worktree, the recorded
# agent_path= in state/<id>.meta, and the placement carried into the launch - so
# it is pinned here with a fake terminal and real git worktrees rather than any
# installed harness.
#
# The two universal facts are all that may be validated: the path exists as a
# directory, and it resolves inside the task's worktree. Nothing about what the
# directory CONTAINS may be inspected, because firstmate serves every kind of
# repository and a build file, manifest, or project shape baked in here would be
# one project's layout imposed on all of them. The empty-directory case below is
# what keeps that honest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agent-path)
TASK_TMPS=()

agent_path_cleanup() {
  local t
  for t in ${TASK_TMPS[@]+"${TASK_TMPS[@]}"}; do
    case "$t" in /tmp/fm-*) rm -rf "$t" ;; esac
  done
}
trap agent_path_cleanup EXIT

# A fake tmux that records what the pane was asked to run. Literal sends (the
# launch command) land in $FM_FAKE_DIR/literal; keyed sends land in keys. The
# pane's reported cwd and foreground command come from files the case controls,
# which is what lets one fixture stand in for a settled fresh pane and for an
# agent-free pane awaiting relaunch.
make_fakebin() {  # <case-dir> -> fakebin path
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$D/literal"
    else
      printf '%s\n' "${1:-}" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf 'pane\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# new_case <name> <id> [seed-fn] -> case dir with a firstmate home, a project, a
# real worktree of it, a brief, and a fake terminal whose pane already sits in
# the worktree (the settled state treehouse get leaves behind).
#
# seed-fn, when given, is called with the project directory before its origin is
# cloned. A fresh spawn resets its worktree to origin's default branch, so
# anything a case needs to find in the worktree has to be committed there first.
new_case() {  # <name> <id> [seed-fn]
  local name=$1 id=$2 seed=${3:-} dir home proj wt
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$home/projects" "$dir/fake"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '# brief for %s\n\nDelivery contract: mode=no-mistakes\n\nDo the thing.\n' \
    "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  [ -z "$seed" ] || "$seed" "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" worktree add --quiet -b "task-$id" "$wt"
  make_fakebin "$dir" > /dev/null
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  : > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    "$SPAWN" "$@" 2>&1
}

launch_line() {  # <case-dir> -> the launch command the pane was given
  tail -n 1 "$1/fake/literal"
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

# --- 1. a valid subdirectory places the agent there and records it ----------

# The subdirectory is deliberately EMPTY: no build file, no manifest, no source.
# If any project-shape check ever creeps into the flag, this case fails first.
test_valid_subdirectory_places_and_records() {
  local dir id out rc
  id=ap-place-a1
  dir=$(new_case place "$id")
  mkdir -p "$dir/wt/module"

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off --agent-path module)
  rc=$?
  expect_code 0 "$rc" "a spawn into an existing worktree subdirectory should succeed"$'\n'"$out"
  assert_contains "$out" "agent-path=$dir/wt/module" "the outcome line should name the starting directory"
  [ "$(meta_field "$dir" "$id" agent_path)" = "$dir/wt/module" ] \
    || fail "meta must record the resolved starting directory, got '$(meta_field "$dir" "$id" agent_path)'"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] \
    || fail "the recorded worktree must still be the worktree root"
  assert_contains "$(launch_line "$dir")" "cd '$dir/wt/module' &&" \
    "the launch must place the agent in the recorded starting directory"
  pass "fm-spawn --agent-path: an existing (and empty) worktree subdirectory places the agent there and is recorded"
}

# The same resolution from an absolute path already inside the worktree.
test_absolute_path_inside_the_worktree_is_accepted() {
  local dir id out rc
  id=ap-abs-a2
  dir=$(new_case abs "$id")
  mkdir -p "$dir/wt/deep/module"

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off \
    --agent-path "$dir/wt/deep/module")
  rc=$?
  expect_code 0 "$rc" "an absolute path inside the worktree should be accepted"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" agent_path)" = "$dir/wt/deep/module" ] \
    || fail "meta must record the absolute starting directory"
  pass "fm-spawn --agent-path: an absolute path inside the worktree resolves and is recorded"
}

# --- 2. omitting the flag is unchanged --------------------------------------

test_absent_flag_is_todays_behaviour() {
  local dir id out rc line
  id=ap-absent-a3
  dir=$(new_case absent "$id")

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 0 "$rc" "a spawn with no --agent-path should succeed"$'\n'"$out"
  assert_not_contains "$out" "agent-path=" "the outcome line must not mention a starting directory"
  assert_no_grep "agent_path=" "$dir/home/state/$id.meta" \
    "meta must record no agent_path= line when the flag was never passed"
  line=$(launch_line "$dir")
  assert_not_contains "$line" "cd " "the launch command must carry no placement step"
  case "$line" in
    cd*) fail "the launch command must not begin with a directory change" ;;
  esac
  pass "fm-spawn: omitting --agent-path records no starting directory and leaves the launch command unchanged"
}

# --- 3. a path that does not exist is refused -------------------------------

test_missing_path_is_refused() {
  local dir id out rc
  id=ap-missing-a4
  dir=$(new_case missing "$id")

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off --agent-path module)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a starting directory that does not exist must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "is not an existing directory inside the task worktree" \
    "the refusal should say the directory does not exist"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no task record"
  pass "fm-spawn --agent-path: a path that does not exist refuses the spawn"
}

test_file_instead_of_directory_is_refused() {
  local dir id out rc
  id=ap-file-a5
  dir=$(new_case file "$id")

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off --agent-path README.md)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a starting path that is a file must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "is not an existing directory inside the task worktree" \
    "the refusal should say the path is not a directory"
  pass "fm-spawn --agent-path: a file where a directory was named refuses the spawn"
}

# --- 4. a path that escapes the worktree is refused -------------------------

test_relative_escape_is_refused() {
  local dir id out rc
  id=ap-escape-a6
  dir=$(new_case escape "$id")

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off --agent-path ../..)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a relative path climbing out of the worktree must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "outside the task worktree" \
    "the refusal should say the path escapes the worktree"
  assert_absent "$dir/home/state/$id.meta" "a refused spawn must publish no task record"
  pass "fm-spawn --agent-path: a relative path climbing out of the worktree refuses the spawn"
}

test_absolute_escape_is_refused() {
  local dir id out rc
  id=ap-absescape-a7
  dir=$(new_case absescape "$id")
  mkdir -p "$dir/outside"

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off \
    --agent-path "$dir/outside")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an absolute path outside the worktree must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "outside the task worktree" \
    "the refusal should say the path escapes the worktree"
  pass "fm-spawn --agent-path: an absolute path outside the worktree refuses the spawn"
}

# A symlink that LOOKS like it is inside the worktree but resolves outside is
# the sharpest escape: only a physical resolution catches it.
seed_escaping_symlink() {  # <project-dir>
  local proj=$1
  ln -s ../.. "$proj/module"
  git -C "$proj" add module
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'module symlink pointing out of the tree'
}

test_symlink_escape_is_refused() {
  local dir id out rc
  id=ap-symlink-a8
  dir=$(new_case symlink "$id" seed_escaping_symlink)

  out=$(run_spawn "$dir" "$id" "$dir/proj" --mode no-mistakes --yolo off --agent-path module)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a symlink out of the worktree must refuse the spawn"$'\n'"$out"
  assert_contains "$out" "outside the task worktree" \
    "the refusal should name where the symlink actually resolves"
  pass "fm-spawn --agent-path: a symlink inside the worktree that resolves outside it refuses the spawn"
}

# --- 5. relaunch preserves the starting directory ---------------------------

# fm-control.sh relaunch rebuilds a worker from its recorded metadata. A
# replacement that fell back to the worktree root would widen a worker's scope
# with nothing to show for it.
test_relaunch_preserves_the_starting_directory() {
  local dir id out rc
  id=ap-relaunch-a9
  dir=$(new_case relaunch "$id")
  mkdir -p "$dir/wt/module"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt" "agent_path=$dir/wt/module" "project=$dir/proj" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "tasktmp=/tmp/fm-$id" "model=default" "effort=default"
  printf '%s' "$dir/wt/module" > "$dir/fake/cwd"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"

  out=$(run_spawn "$dir" "$id" --relaunch)
  rc=$?
  expect_code 0 "$rc" "a relaunch of a task with a recorded starting directory should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" agent_path)" = "$dir/wt/module" ] \
    || fail "the recorded starting directory must survive a relaunch"
  assert_contains "$(launch_line "$dir")" "cd '$dir/wt/module' &&" \
    "the replacement agent must be launched in the recorded starting directory"
  pass "fm-spawn --relaunch: the recorded starting directory is preserved and carried into the replacement launch"
}

# The pane must be where the task's agent actually runs, not merely somewhere in
# the worktree, so a drifted pane cannot silently widen the replacement's scope.
test_relaunch_refuses_a_pane_outside_the_recorded_starting_directory() {
  local dir id out rc
  id=ap-relaunch-drift-b1
  dir=$(new_case relaunchdrift "$id")
  mkdir -p "$dir/wt/module"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt" "agent_path=$dir/wt/module" "project=$dir/proj" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "tasktmp=/tmp/fm-$id" "model=default" "effort=default"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"

  out=$(run_spawn "$dir" "$id" --relaunch)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a pane at the worktree root must refuse a relaunch scoped to a subdirectory"$'\n'"$out"
  assert_contains "$out" "not its recorded starting directory '$dir/wt/module'" \
    "the refusal should name the recorded starting directory"
  pass "fm-spawn --relaunch: a pane outside the recorded starting directory refuses rather than widening scope"
}

# A recorded starting directory that has since moved outside the worktree is
# re-validated, not trusted.
test_relaunch_revalidates_a_recorded_escape() {
  local dir id out rc
  id=ap-relaunch-escape-b2
  dir=$(new_case relaunchescape "$id")
  mkdir -p "$dir/outside"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt" "agent_path=$dir/outside" "project=$dir/proj" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "tasktmp=/tmp/fm-$id" "model=default" "effort=default"
  printf '%s' "$dir/outside" > "$dir/fake/cwd"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"

  out=$(run_spawn "$dir" "$id" --relaunch)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a recorded starting directory outside the worktree must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "outside the task worktree" \
    "the refusal should say the recorded directory escapes the worktree"
  pass "fm-spawn --relaunch: a recorded starting directory outside the worktree is refused, not trusted"
}

test_relaunch_refuses_an_agent_path_override() {
  local dir id out rc
  id=ap-relaunch-override-b3
  dir=$(new_case relaunchoverride "$id")
  mkdir -p "$dir/wt/module"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt" "project=$dir/proj" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "tasktmp=/tmp/fm-$id" "model=default" "effort=default"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"

  out=$(run_spawn "$dir" "$id" --relaunch --agent-path module)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--agent-path must not override a task's recorded starting directory"$'\n'"$out"
  assert_contains "$out" "--relaunch reuses the task's recorded starting directory" \
    "the refusal should point at the recorded value"
  pass "fm-spawn --relaunch: --agent-path is refused as an identity-axis override"
}

# --- 6. the flag's boundaries ----------------------------------------------

test_home_owning_kinds_refuse_the_flag() {
  local dir id out rc
  id=ap-secondmate-b4
  dir=$(new_case secondmate "$id")

  out=$(run_spawn "$dir" "$id" "$dir/proj" --secondmate --agent-path module)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--agent-path must be refused for a secondmate spawn"$'\n'"$out"
  assert_contains "$out" "applies to ship and scout spawns only" \
    "the refusal should say which spawns accept a starting directory"

  out=$(run_spawn "$dir" "sup-$id" --supervisor --agent-path module)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--agent-path must be refused for a supervisor spawn"$'\n'"$out"
  assert_contains "$out" "applies to ship and scout spawns only" \
    "the refusal should say which spawns accept a starting directory"
  pass "fm-spawn --agent-path: a secondmate and a temporary supervisor refuse it and keep their own home"
}

test_batch_dispatch_refuses_a_shared_starting_directory() {
  local dir out rc
  dir=$(new_case batch ap-batch-b5)

  out=$(run_spawn "$dir" "one=$dir/proj" "two=$dir/proj" \
    --mode no-mistakes --yolo off --agent-path module)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a batch must refuse one shared starting directory"$'\n'"$out"
  assert_contains "$out" "not a shared batch axis" \
    "the refusal should say a starting directory belongs to one task"
  pass "fm-spawn --agent-path: batch dispatch refuses it as a shared axis"
}

test_empty_value_is_refused() {
  local dir out rc
  dir=$(new_case emptyval ap-empty-b6)

  out=$(run_spawn "$dir" ap-empty-b6 "$dir/proj" --mode no-mistakes --yolo off --agent-path '')
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty --agent-path value must be refused"$'\n'"$out"
  assert_contains "$out" "--agent-path requires a non-empty value" \
    "the refusal should name the empty flag value"
  pass "fm-spawn --agent-path: an empty value is refused"
}

# --- 7. the one adapter that does not simply inherit the pane's directory ---

# Cursor takes --workspace rather than reading the pane's cwd, so the same
# starting directory has to reach that flag or the placement would be silently
# ignored for exactly one harness.
test_cursor_workspace_follows_the_starting_directory() {
  local dir id out rc bin
  id=ap-cursor-b7
  dir=$(new_case cursor "$id")
  mkdir -p "$dir/wt/module"
  bin="$dir/cursorinstall/bin"
  mkdir -p "$bin" "$dir/cursorinstall/share/cursor-agent/versions/2026.08.11-e8db854"
  printf '#!/bin/sh\necho "Start the Cursor Agent"\n' \
    > "$dir/cursorinstall/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent"
  chmod +x "$dir/cursorinstall/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent"
  ln -sf "$dir/cursorinstall/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent" \
    "$bin/cursor-agent"

  out=$(env PATH="$dir/fakebin:$bin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" CURSOR_PROJECTS_ROOT_OVERRIDE="$dir/cursorprojects" \
    "$SPAWN" "$id" "$dir/proj" --mode no-mistakes --yolo off --harness cursor \
    --agent-path module 2>&1)
  rc=$?
  expect_code 0 "$rc" "a cursor spawn with a starting directory should succeed"$'\n'"$out"
  assert_contains "$(launch_line "$dir")" "--workspace '$dir/wt/module'" \
    "cursor's workspace must be the starting directory, not the worktree root"
  assert_grep "workspace_root=$dir/wt/module" "$dir/home/state/$id.cursor-session" \
    "the cursor turn-state binding must follow the directory cursor was actually given"
  pass "fm-spawn --agent-path: cursor's --workspace and turn-state binding follow the starting directory"
}

test_valid_subdirectory_places_and_records
test_absolute_path_inside_the_worktree_is_accepted
test_absent_flag_is_todays_behaviour
test_missing_path_is_refused
test_file_instead_of_directory_is_refused
test_relative_escape_is_refused
test_absolute_escape_is_refused
test_symlink_escape_is_refused
test_relaunch_preserves_the_starting_directory
test_relaunch_refuses_a_pane_outside_the_recorded_starting_directory
test_relaunch_revalidates_a_recorded_escape
test_relaunch_refuses_an_agent_path_override
test_home_owning_kinds_refuse_the_flag
test_batch_dispatch_refuses_a_shared_starting_directory
test_empty_value_is_refused
test_cursor_workspace_follows_the_starting_directory

echo "# all fm-spawn-agent-path tests passed"
