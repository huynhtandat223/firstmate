#!/usr/bin/env bash
# Exercise bin/fm-teardown.sh on a task spawned with --also-repo (firstmate#176 G6): each also_worktree= copy in the
# task meta passes the same landed-work test as the main copy before anything is returned, and a landed copy goes
# back to its pool under the task's own lease. Real git repositories and worktrees; a fake treehouse logs its calls.
set -u

# shellcheck source=tests/verify-gate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/verify-gate-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-also-repo)

repo_with_origin() {  # <case-dir> <name>: a bare origin with one commit and a clone of it under <case-dir>/<name>
  local case_dir=$1 name=$2
  git init -q --bare "$case_dir/$name.git"
  git -C "$case_dir/$name.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/$name.git" "$case_dir/_seed-$name" 2>/dev/null
  git -C "$case_dir/_seed-$name" commit -q --allow-empty -m "$name baseline"
  git -C "$case_dir/_seed-$name" push -q origin main
  rm -rf "$case_dir/_seed-$name"
  git clone -q "$case_dir/$name.git" "$case_dir/$name"
  git -C "$case_dir/$name" remote set-head origin main 2>/dev/null || true
}

make_case() {  # <name>: sets CASE; main copy $CASE/wt of $CASE/project, second copy $CASE/also of $CASE/dms
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/state" "$CASE/config" "$CASE/data" "$CASE/fakebin"
  cat > "$CASE/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_TREEHOUSE_LOG"
exit 0
SH
  cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$CASE/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$CASE/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$CASE/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE/fakebin/"*
  repo_with_origin "$CASE" project
  repo_with_origin "$CASE" dms
  git -C "$CASE/project" worktree add -q -b fm/task-x1 "$CASE/wt" main
  git -C "$CASE/dms" worktree add -q -b fm/task-x1 "$CASE/also" main
  touch "$CASE/state/.last-watcher-beat"
  fm_write_meta "$CASE/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$CASE/wt" \
    "also_worktree=$CASE/also" \
    "project=$CASE/project" \
    "kind=ship" \
    "mode=direct-PR" \
    "spawn_gen=teardown-also-task-x1"
  export FAKE_TREEHOUSE_LOG="$CASE/treehouse.log"
  : > "$FAKE_TREEHOUSE_LOG"
}

commit_in() {  # <copy> <file>: a real change committed on the copy's task branch
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "add $2"
}

push_in() {  # <copy>: push the copy's task branch to its origin
  git -C "$1" push -q origin fm/task-x1
}

run_teardown() {
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$CASE/state" FM_DATA_OVERRIDE="$CASE/data" \
    FM_CONFIG_OVERRIDE="$CASE/config" PATH="$CASE/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" > "$CASE/stdout" 2> "$CASE/stderr"
  RC=$?
}

refused_with_everything_kept() {  # <label>
  [ "$RC" = 1 ] || fail "$1: teardown exited $RC, not a refusal: $(cat "$CASE/stderr")"
  grep -F "$CASE/also" "$CASE/stderr" | grep -q REFUSED || fail "$1: the refusal does not name the second copy: $(cat "$CASE/stderr")"
  [ -e "$CASE/state/task-x1.meta" ] || fail "$1: the task record was removed"
  [ ! -s "$FAKE_TREEHOUSE_LOG" ] || fail "$1: a copy was returned: $(cat "$FAKE_TREEHOUSE_LOG")"
}

make_case landed
commit_in "$CASE/wt" main.txt && push_in "$CASE/wt"
commit_in "$CASE/also" chip.txt && push_in "$CASE/also"
run_teardown
[ "$RC" = 0 ] || fail "landed: teardown failed: $(cat "$CASE/stderr")"
grep -qx "return --force $CASE/wt" "$FAKE_TREEHOUSE_LOG" || fail "landed: the main copy was not returned: $(cat "$FAKE_TREEHOUSE_LOG")"
grep -qx "return --force $CASE/also --if-lease-holder task-x1" "$FAKE_TREEHOUSE_LOG" \
  || fail "landed: the second copy was not returned under the task's lease: $(cat "$FAKE_TREEHOUSE_LOG")"
[ ! -e "$CASE/state/task-x1.meta" ] || fail "landed: the task record survived"
pass 'a landed second repository copy is returned under the task lease with the main copy'

make_case unlanded
commit_in "$CASE/wt" main.txt && push_in "$CASE/wt"
commit_in "$CASE/also" chip.txt
run_teardown
refused_with_everything_kept unlanded
pass 'a second copy with work on no remote and not landed refuses the whole cleanup before any return'

make_case dirty
commit_in "$CASE/wt" main.txt && push_in "$CASE/wt"
printf 'draft\n' > "$CASE/also/draft.txt"
run_teardown
refused_with_everything_kept dirty
pass 'a second copy with uncommitted changes refuses the whole cleanup before any return'

make_case forced
commit_in "$CASE/also" chip.txt
run_teardown --force
[ "$RC" = 0 ] || fail "forced: teardown --force failed: $(cat "$CASE/stderr")"
grep -qx "return --force $CASE/also --if-lease-holder task-x1" "$FAKE_TREEHOUSE_LOG" \
  || fail "forced: the second copy was not returned: $(cat "$FAKE_TREEHOUSE_LOG")"
pass '--force returns the second copy too'
