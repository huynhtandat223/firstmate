#!/usr/bin/env bash
# Behavior tests for the environment leases of bin/fm-lease.sh (firstmate#176 G5): a resource `env:<name>` held by
# one holder at a time (the Tester assistance or a task id). Each case drives the real CLI against a real tmux server
# on a private socket, so a live holder is a real window and a dead pane is a window that is gone. The mutation
# proofs at the end remove one guard at a time from a copy of the lease scripts and show its case go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
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

new_home() {  # <bin-dir>: a home whose tester and alpha have live windows and beta's window is gone
  H=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  LB=$1
  mkdir -p "$H/state"
  export FM_HOME="$H"
  printf 'kind=assistance\nbackend=tmux\nwindow=lease:tester\n' > "$H/state/tester.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=lease:alpha\n' > "$H/state/alpha.meta"
  printf 'kind=ship\nbackend=tmux\nwindow=lease:beta\n' > "$H/state/beta.meta"
}
lease() { "$LB/fm-lease.sh" "$@"; }

# The Tester holds env:company; a worker's claim is refused with the holder named; check prints the holder; the
# holder refreshes its own lease.
case_refuse() {
  local out rc
  new_home "$1"
  lease claim env:company --holder tester || { echo "the Tester could not claim a free env:company"; return 1; }
  out=$(lease claim env:company --holder alpha 2>&1)
  rc=$?
  [ "$rc" = 6 ] || { echo "a claim on a held env lease exited $rc, not 6: $out"; return 1; }
  case "$out" in *"held by tester"*) ;; *) echo "the refusal does not name the holder: $out"; return 1 ;; esac
  out=$(lease check env:company) || { echo "check found no env lease"; return 1; }
  case "$out" in "tester "[0-9]*" live") ;; *) echo "check: $out"; return 1 ;; esac
  lease claim env:company --holder tester || { echo "the holder could not refresh its own env lease"; return 1; }
}

# Only the holder releases, a second release is a no-op, and a released lease can be claimed.
case_release() {
  local out
  new_home "$1"
  lease claim env:company --holder tester || return 1
  out=$(lease release env:company --holder alpha 2>&1)
  [ "$?" = 6 ] || { echo "releasing another holder's env lease was not refused: $out"; return 1; }
  lease check env:company >/dev/null || { echo "another holder's release removed the lease"; return 1; }
  lease release env:company --holder tester || { echo "the holder could not release"; return 1; }
  lease release env:company --holder tester || { echo "a second release was not a no-op"; return 1; }
  ! lease check env:company >/dev/null 2>&1 || { echo "the env lease is still held after release"; return 1; }
  lease claim env:company --holder alpha || { echo "a worker could not claim a released env lease"; return 1; }
}

# A holder whose pane is gone is stale, and a claim replaces it.
case_dead_pane() {
  new_home "$1"
  lease claim env:company --holder beta || return 1
  [ "$(lease check env:company | cut -d' ' -f3)" = stale ] || { echo "a holder with no live window reads live: $(lease check env:company)"; return 1; }
  lease claim env:company --holder alpha 2>/dev/null || { echo "a claim did not replace a lease whose holder pane is dead"; return 1; }
}

# Sweep removes the lease of a gone task (no meta) and keeps a live one.
case_sweep() {
  new_home "$1"
  lease claim env:company --holder gamma || return 1
  lease claim env:home --holder tester || return 1
  lease sweep || { echo "sweep failed"; return 1; }
  ! lease check env:company >/dev/null 2>&1 || { echo "sweep left a lease whose holder has no meta"; return 1; }
  lease check env:home | grep -q '^tester .* live$' || { echo "sweep removed a live env lease"; return 1; }
}

# An env claim needs --holder and a safe name.
case_usage() {
  local out
  new_home "$1"
  out=$(lease claim env:company 2>&1)
  [ "$?" = 2 ] || { echo "an env claim with no --holder was accepted: $out"; return 1; }
  out=$(lease claim 'env:a/b' --holder tester 2>&1)
  [ "$?" = 2 ] || { echo "an unsafe env name was accepted: $out"; return 1; }
}

for c in refuse release dead_pane sweep usage; do
  out=$(case_"$c" "$ROOT/bin" 2>&1) || fail "case $c: $out"
  pass "env lease $c"
done

# ---- mutation proofs ------------------------------------------------------------
MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp "$ROOT"/bin/*.sh "$MBIN/"
mkdir -p "$MBIN/backends"
cp "$ROOT"/bin/backends/*.sh "$MBIN/backends/"
cp "$MBIN/fm-lease.sh" "$TMP_ROOT/cli.orig"
cp "$MBIN/fm-lease-lib.sh" "$TMP_ROOT/lib.orig"
mutate() {  # <label> <case> <cli|lib> <perl-substitution>
  local file=$MBIN/fm-lease.sh orig=$TMP_ROOT/cli.orig
  [ "$3" = cli ] || { file=$MBIN/fm-lease-lib.sh; orig=$TMP_ROOT/lib.orig; }
  cp "$TMP_ROOT/cli.orig" "$MBIN/fm-lease.sh"
  cp "$TMP_ROOT/lib.orig" "$MBIN/fm-lease-lib.sh"
  perl -0pi -e "$4" "$file"
  cmp -s "$orig" "$file" && fail "mutation '$1' changed nothing"
  if out=$(case_"$2" "$MBIN" 2>&1); then fail "removing the guard '$1' left case $2 green"; fi
  pass "guard '$1' is needed: case $2 goes red without it"
}
mutate 'a live lease of another holder refuses a claim' refuse cli \
  's/if fm_lease_env_live "\$ENV_NAME" && \[ "\$FM_LEASE_HOLDER" != "\$HOLDER" \]; then/if false; then/'
mutate 'only the holder releases' release cli \
  's/if \[ "\$FM_LEASE_HOLDER" != "\$HOLDER" \] && fm_lease_env_live "\$ENV_NAME"; then/if false; then/'
mutate 'a dead pane is stale' dead_pane lib \
  's/fm_backend_target_exists "\$\{backend:-tmux\}" "\$window"/true/'
mutate 'a gone task is stale' sweep lib \
  's/\[ -f "\$meta" \] \|\| return 1/:/'
mutate 'sweep removes a stale env lease' sweep cli \
  's/fm_lease_env_live "\$ENV_NAME" \|\| rm -f -- "\$LEASE"/:/'
mutate 'an env claim needs a holder' usage cli \
  's/claim\)\n      fm_lease_valid_id "\$HOLDER" \|\| usage/claim)\n      [ -n "\$HOLDER" ] || HOLDER=nobody/'
pass 'every env lease guard has a red mutation proof'
