#!/usr/bin/env bash
# Behavior tests for the environment leases of bin/fm-lease.sh (firstmate#176 G5): a resource `env:<name>` held by
# one holder at a time (the Tester assistance or a task id). Each case drives the real CLI against a real tmux server
# on a private socket, so a live holder is a real window and a dead pane is a window that is gone.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-lease-env)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-lease-env-$$"
trap '"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true' EXIT
mkdir -p "$TMP_ROOT/shim"
printf '#!/usr/bin/env bash\nexec "%s" -f /dev/null -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$TMP_ROOT/shim/tmux"
chmod +x "$TMP_ROOT/shim/tmux"
export PATH="$TMP_ROOT/shim:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_SUPERVISION_ACTOR PI_CODING_AGENT
tmux new-session -d -s lease -n tester -x 80 -y 20 || fail "tmux new-session failed"
tmux new-window -d -t lease -n alpha || fail "tmux new-window failed"

H="$TMP_ROOT/home"
mkdir -p "$H/state"
export FM_HOME="$H"
printf 'kind=assistance\nbackend=tmux\nwindow=lease:tester\n' > "$H/state/tester.meta"
printf 'kind=ship\nbackend=tmux\nwindow=lease:alpha\n' > "$H/state/alpha.meta"
printf 'kind=ship\nbackend=tmux\nwindow=lease:beta\n' > "$H/state/beta.meta"
lease() { "$ROOT/bin/fm-lease.sh" "$@"; }

# The Tester holds env:company; a worker's claim is refused with the holder named.
lease claim env:company --holder tester || fail "the Tester could not claim a free env:company"
out=$(lease claim env:company --holder alpha 2>&1)
rc=$?
[ "$rc" = 6 ] || fail "a claim on a held env lease exited $rc, not 6: $out"
case "$out" in *"held by tester"*) ;; *) fail "the refusal does not name the holder: $out" ;; esac
pass "a claim on a live env lease is refused with the holder named"

out=$(lease check env:company) || fail "check found no env lease"
case "$out" in "tester "[0-9]*" live") ;; *) fail "check: $out" ;; esac
lease claim env:company --holder tester || fail "the holder could not refresh its own env lease"
pass "check prints the holder, and the holder refreshes its own lease"

# Release: another holder is refused, the holder releases, and a second release is a no-op.
out=$(lease release env:company --holder alpha 2>&1)
[ "$?" = 6 ] || fail "releasing another holder's env lease was not refused: $out"
lease release env:company --holder tester || fail "the holder could not release"
lease release env:company --holder tester || fail "a second release was not a no-op"
! lease check env:company >/dev/null 2>&1 || fail "the env lease is still held after release"
lease claim env:company --holder alpha || fail "a worker could not claim a released env lease"
pass "only the holder releases, and a released env lease can be claimed"

# A dead pane is stale: a claim replaces it and sweep removes it.
lease release env:company --holder alpha
lease claim env:company --holder beta || fail "claim for beta"
[ "$(lease check env:company | cut -d' ' -f3)" = stale ] || fail "a holder with no live window reads live: $(lease check env:company)"
lease claim env:company --holder alpha || fail "a claim did not replace a lease whose holder pane is dead"
pass "a holder whose pane is gone is stale and a claim replaces it"

# A gone task is stale; sweep removes it and keeps a live lease.
lease release env:company --holder alpha
lease claim env:company --holder gamma || fail "claim for gamma"
lease claim env:home --holder tester || fail "claim env:home"
lease sweep || fail "sweep failed"
! lease check env:company >/dev/null 2>&1 || fail "sweep left a lease whose holder has no meta"
lease check env:home | grep -q '^tester .* live$' || fail "sweep removed a live env lease"
pass "sweep removes a lease of a gone task and keeps a live one"

# Usage: an env claim needs --holder and a safe name; a task lease stays as it was.
out=$(lease claim env:company 2>&1)
[ "$?" = 2 ] || fail "an env claim with no --holder was accepted: $out"
out=$(lease claim 'env:a/b' --holder tester 2>&1)
[ "$?" = 2 ] || fail "an unsafe env name was accepted: $out"
pass "an env claim needs --holder and a safe name"
