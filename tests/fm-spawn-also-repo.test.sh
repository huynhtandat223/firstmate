#!/usr/bin/env bash
# Exercise the real spawn boundary for --also-repo (firstmate#176 G6): a task that needs a second repository starts
# with a durably leased Treehouse copy of it, named in its meta and brief, and a bad request is refused before
# anything is created. Fake terminal and a fake treehouse that hands out a real git worktree of the named project.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-also-repo)

new_case() {  # <case>
  label=$1
  home="$TMP_ROOT/$1"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" also
  fm_git_worktree "$home/projects/demo" "$home/pane" "fixture-$1"
  fm_git_worktree "$home/projects/dms-workspaces" "$home/dms-copy" "dms-$1"
  fakebin=$(fm_test_make_spawn_fakebin "$home/tools" claude)
  fm_test_fake_gh "$fakebin"
  cat > "$fakebin/treehouse" <<'TH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_TREEHOUSE_LOG"
case "$1 ${2:-}" in
  "get --lease") printf '%s\n' "$FAKE_TREEHOUSE_COPY" ;;
esac
exit 0
TH
  chmod +x "$fakebin/treehouse"
  export FAKE_TREEHOUSE_LOG="$home/treehouse.log" FAKE_TREEHOUSE_COPY="$home/dms-copy"
  : > "$FAKE_TREEHOUSE_LOG"
  tasks-axi add also "Build the debug chip" --kind ship --file "$home/data/backlog.md" >/dev/null
}
spawn() {
  out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" also "$home/projects/demo" --mode direct-PR --yolo off "$@")
  status=$?
}
refused_cleanly() {
  [ "$status" != 0 ] || fail "$label did not refuse: $out"
  [ ! -e "$home/state/also.meta" ] || fail "$label created meta"
  [ ! -e "$fakebin/.spawn-window" ] || fail "$label created an endpoint"
  ! grep -q 'get --lease' "$FAKE_TREEHOUSE_LOG" || fail "$label leased a copy: $(cat "$FAKE_TREEHOUSE_LOG")"
}

new_case leased
spawn --also-repo dms-workspaces
[ "$status" = 0 ] || fail "$label failed to launch: $out"
assert_grep "also_worktree=$home/dms-copy" "$home/state/also.meta" "$label: meta does not name the second copy"
grep -qx "$home/projects/dms-workspaces|get --lease --lease-holder also" "$FAKE_TREEHOUSE_LOG" \
  || fail "$label: the copy was not leased durably for the task from that project: $(cat "$FAKE_TREEHOUSE_LOG")"
assert_grep "dms-workspaces: $home/dms-copy" "$home/data/also/brief.md" "$label: the brief does not list the second copy"
pass 'a spawn with --also-repo leases a copy of that project for the task and names it in the meta and brief'

new_case unknown
spawn --also-repo no-such-project
refused_cleanly
printf '%s\n' "$out" | grep -F 'no-such-project' >/dev/null || fail "$label: the refusal does not name the project: $out"
pass 'an --also-repo project with no clone in this home is refused before anything is created'

new_case scout
out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" also "$home/projects/demo" --scout --also-repo dms-workspaces)
status=$?
[ "$status" = 0 ] || fail "$label failed to launch: $out"
assert_grep "also_worktree=$home/dms-copy" "$home/state/also.meta" "$label: a scout's meta does not name the second copy"
pass 'a scout can take a second copy too'

new_case primary
export FAKE_TREEHOUSE_COPY="$home/projects/dms-workspaces"
spawn --also-repo dms-workspaces
[ "$status" != 0 ] || fail "$label accepted the project's primary checkout as its second copy: $out"
[ ! -e "$home/state/also.meta" ] || fail "$label created meta"
grep -q "|return --force $home/projects/dms-workspaces" "$FAKE_TREEHOUSE_LOG" \
  || fail "$label: the refused lease was not returned: $(cat "$FAKE_TREEHOUSE_LOG")"
pass 'a lease that is not an isolated copy is returned and the spawn refused'
