#!/usr/bin/env bash
# Exercise the real spawn boundary for --surface: a ship spawn into cfw-modules must say whether
# the task is user-visible, and a user-visible spawn starts firstmate's verification record
# (bin/fm-verify-gate-lib.sh) with the issue its backlog item links. Fake terminal, real backlog.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-surface)
url=https://github.com/o/r/issues/7

# A temp home with a registered project of the given name and a backlog row (linking <url> when
# given). Each pane reports a test-owned isolated copy.
new_case() {  # <case> <project> <title-suffix>
  label=$1
  home="$TMP_ROOT/$1"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" surf
  fm_git_worktree "$home/projects/$2" "$home/pane" "fixture-$1"
  fakebin=$(fm_test_make_spawn_fakebin "$home/tools" claude)
  fm_test_fake_gh "$fakebin"
  tasks-axi add surf "Build $3" --kind ship --file "$home/data/backlog.md" >/dev/null
  project="$home/projects/$2"
}
spawn() {
  out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" surf "$project" --mode direct-PR --yolo off "$@")
  status=$?
}
expect() {
  printf '%s\n' "$out" | grep -F -- "$1" >/dev/null || fail "$label: missing '$1': $out"
}
refused_cleanly() {
  [ "$status" != 0 ] || fail "$label did not refuse: $out"
  [ ! -e "$home/state/surf.meta" ] || fail "$label created meta"
  [ ! -e "$fakebin/.spawn-window" ] || fail "$label created endpoint"
  [ ! -e "$home/data/surf/verify.md" ] || fail "$label wrote a verification record"
}
launched() {
  [ "$status" = 0 ] || fail "$label failed to launch: $out"
  [ -e "$home/state/surf.meta" ] || fail "$label wrote no task record"
}

new_case cfw-missing cfw-modules "$url"
spawn
refused_cleanly
expect '--surface user-visible or --surface internal'
pass 'a cfw-modules ship spawn without --surface is refused before anything is created'

new_case cfw-internal cfw-modules "$url"
spawn --surface internal
launched
assert_grep 'surface=internal' "$home/state/surf.meta" "$label: meta lacks the surface"
[ ! -e "$home/data/surf/verify.md" ] || fail "$label wrote a verification record for an internal task"
pass 'a cfw-modules ship spawn with --surface internal launches without a verification record'

new_case cfw-visible cfw-modules "$url"
spawn --surface user-visible
launched
assert_grep 'surface=user-visible' "$home/state/surf.meta" "$label: meta lacks the surface"
[ "$(cat "$home/data/surf/verify.md")" = "$(printf 'surface: user-visible\nissue: %s' "$url")" ] \
  || fail "$label: verify.md header is wrong: $(cat "$home/data/surf/verify.md" 2>&1)"
pass 'a cfw-modules user-visible spawn writes verify.md with surface: and issue:'

new_case visible-no-issue cfw-modules ''
spawn --surface user-visible
refused_cleanly
expect 'link it with bin/fm-tasks-axi.sh update surf'
pass 'a user-visible spawn whose backlog item links no issue is refused'

new_case other-visible demo "$url"
spawn --surface user-visible
launched
assert_grep "issue: $url" "$home/data/surf/verify.md" "$label: verify.md lacks the issue"
pass 'a user-visible spawn in another project writes the same record header'

new_case other-default demo "$url"
spawn
launched
[ ! -e "$home/data/surf/verify.md" ] || fail "$label wrote a verification record"
assert_no_grep 'surface=' "$home/state/surf.meta" "$label: a default spawn recorded a surface"
pass 'a spawn into another project without --surface behaves as before'

new_case existing-record cfw-modules "$url"
printf 'surface: user-visible\nissue: %s\napproved: firstmate 5\n' "$url" > "$home/data/surf/verify.md"
spawn --surface user-visible
launched
assert_grep 'approved: firstmate 5' "$home/data/surf/verify.md" "$label: the existing record was overwritten"
pass 'a spawn keeps a verification record that already exists'
