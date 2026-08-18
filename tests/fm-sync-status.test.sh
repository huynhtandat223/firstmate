#!/usr/bin/env bash
# Public-interface behavior tests for the read-only fork sync status command.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
STATUS="$ROOT/bin/fm-sync-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-sync-status)
fm_git_identity fmtest fmtest@example.invalid

repo=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
git -C "$repo" init -q
git -C "$repo" checkout -q -b main
printf 'same\n' > "$repo/file"
git -C "$repo" add file && git -C "$repo" commit -qm initial
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" branch -f origin/main "$base"
git -C "$repo" branch -f upstream/main "$base"
git -C "$repo" commit -q --allow-empty -m 'Sync fork with upstream main (#1)'
out=$($STATUS "$repo")
assert_contains "$out" 'local main matches origin/main' 'default output reports fork equality'
assert_contains "$out" 'upstream/main:' 'default output reports upstream hash'
assert_contains "$out" 'latest sync receipt:' 'default output reports sync receipt'
assert_contains "$out" 'ancestry counts are not a content-sync verdict' 'default output explains squash ancestry'
json=$($STATUS --json "$repo")
assert_contains "$json" '"schema":"fm-sync-status.v1"' 'JSON output has stable schema'
assert_contains "$json" '"local_matches_origin":true' 'JSON output carries equality'
assert_contains "$json" '"source_ref":"upstream/main"' 'JSON output carries receipt source'
# The command must not alter refs or the worktree.
test "$(git -C "$repo" rev-parse main)" = "$(git -C "$repo" rev-parse HEAD)" || fail 'status changed refs'
pass 'sync status reports content and ancestry through its public interface'
