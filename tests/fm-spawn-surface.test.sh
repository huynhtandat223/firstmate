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

new_case visible-task cfw-modules ''
cat > "$home/tools/task-reader" <<'SH'
#!/usr/bin/env bash
[ "$1" = document ] && [ "$2" = surf ] || exit 1
cat <<'MD'
## Context
Probe.
## Requirements
Read acceptance.
## Definition of done
Acceptance passes.
## Scenarios
- [ ] P1 WHEN the task is read, THE spawn SHALL use task acceptance.
  - page: task-board
  - widths: 390
  - controls: -
  - env: Dev 5001
  - proof: command readback
  - data: probe
  - mock: none
  - surface: user-visible
## Mockup
None.
## Links
None.
## Decisions
None.
MD
SH
chmod +x "$home/tools/task-reader"
FM_ACCEPTANCE_TASK="$home/tools/task-reader" spawn --surface user-visible
launched
assert_grep 'issue: task:surf' "$home/data/surf/verify.md" "$label: missing task source"
pass 'a user-visible task with Description acceptance launches without an issue'

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

# While the task record is on (config/task-shadow), a user-visible task begun now is verified on its check rows:
# the record header carries 'record: rows' for bin/fm-verify-gate-lib.sh. The record writer is a no-op stand-in here.
new_case record-on cfw-modules "$url"
mkdir -p "$home/config"; : > "$home/config/task-shadow"
printf '#!/bin/sh\nexit 0\n' > "$home/tools/no-writer"; chmod +x "$home/tools/no-writer"
FM_TASK_SHADOW_WRITER="$home/tools/no-writer" spawn --surface user-visible
launched
[ "$(cat "$home/data/surf/verify.md")" = "$(printf 'surface: user-visible\nissue: %s\nrecord: rows' "$url")" ] \
  || fail "$label: verify.md header is wrong: $(cat "$home/data/surf/verify.md" 2>&1)"
pass 'a user-visible spawn while the task record is on marks the task for the check-row gate'

# Rows come from deploy-verify, which watches one repository (FM_DEPLOY_VERIFY_REPO): a user-visible task in another
# project keeps the file gate and gets no marker.
new_case record-other demo "$url"
mkdir -p "$home/config"; : > "$home/config/task-shadow"
printf '#!/bin/sh\nexit 0\n' > "$home/tools/no-writer"; chmod +x "$home/tools/no-writer"
FM_TASK_SHADOW_WRITER="$home/tools/no-writer" spawn --surface user-visible
launched
[ "$(cat "$home/data/surf/verify.md")" = "$(printf 'surface: user-visible\nissue: %s' "$url")" ] \
  || fail "$label: verify.md header is wrong: $(cat "$home/data/surf/verify.md" 2>&1)"
pass 'a user-visible spawn outside the deploy-verify repository keeps the file gate'
