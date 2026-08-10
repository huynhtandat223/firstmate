#!/usr/bin/env bash
# tests/fm-composer-blank-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness still has its own IDLE composer classified `empty` by
# the shared composer-content owner (bin/fm-composer-lib.sh), and its typed-but-
# unsubmitted composer classified `pending`.
#
# Why this file exists (task fm-pair-delivery-false-negative-fix): what a
# harness draws in an empty composer is a rendering detail its vendor owns and
# changes without notice. Claude 2.1.226 began padding its empty composer row
# with U+00A0 after the `❯` glyph. That blank is not de-emphasised, so the ghost
# stripper correctly kept it, and every trim in the fleet is ASCII-only - so a
# genuinely empty composer classified `pending`. Nothing failed loudly: the
# verdict only decides delivery where no stronger signal exists, so an ordinary
# steer to an idle worker kept confirming through native agent-state while
# herdr's busy-baseline submit confirmation quietly reported
# `delivery unconfirmed; verdict=pending` for messages that had already landed.
# A paired review aborted on one of them after its release message was received.
# A stubbed pane cannot see this class of regression - a fixture can only replay
# the bytes someone already transcribed from a previous release - so the check
# has to run real harnesses.
#
# Each harness is launched bare, with no prompt, and the probe text below is
# TYPED but never submitted, so this consumes no model tokens. The launch uses
# whatever credentials the harness already has.
#
# PROOF OF COMPOSER, not just a verdict. An idle `empty` reading is worthless on
# its own: a pane that is still blank one second after launch, or showing a
# first-run trust dialog, also reads `empty`, and an earlier draft of this guard
# passed against exactly that - it accepted the blank startup screen and never
# looked at a composer at all. So the untouched verdict is recorded first, and
# is only ASSERTED after probe text typed into that same pane has become
# visible on screen: that is what proves the harness had drawn a real, typeable
# composer. A harness that never accepts the probe (a trust dialog or onboarding
# screen owning the keyboard) is reported as unverified rather than passed over
# silently, and does not count toward the checked total.
#
# The windows are opened in the firstmate repo itself rather than a scratch
# directory, because a harness meeting an unknown directory asks to trust it
# before it will draw a composer, which would leave every harness unverified.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterparts pin the classifier logic in
# CI: tests/fm-composer-lib.test.sh for the shared verdict, and
# tests/fm-backend-herdr.test.sh for the busy-baseline submit path this fault
# actually reached. Run this guard after any harness upgrade and before trusting
# refreshed per-harness evidence in docs/verification/runtime-backends.md.
set -u

if [ "${FM_COMPOSER_BLANK_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_BLANK_DRIFT=1 to run the installed-harness composer drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-composer-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-drift.XXXXXX")
SESSION=drift
PROBE='fm composer drift probe'

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirror bin/fm-spawn.sh's own resolution order so this guard covers the same
# binary firstmate would actually launch (kimi need not be on PATH).
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

# The composer row as bytes, so a failure names the exact padding that drifted
# instead of only the verdict it produced.
composer_bytes() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$1" -S -6 2>/dev/null \
    | grep -v '^[[:space:]]*$' | tail -3 | od -c | head -12
}

# Wait until the pane stops redrawing, so a verdict is read from a settled
# screen rather than from a launch still in progress.
wait_settled() {  # <target>
  local target=$1 prev='' now='' stable=0 _
  for _ in $(seq 1 150); do
    now=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S 0 -E - 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" = "$prev" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 4 ] && return 0
    else
      stable=0
    fi
    prev=$now
    sleep 0.2
  done
  return 1
}

# Wait for text typed into the pane to become visible on screen. This is the
# proof that the harness is drawing a real composer and taking our keystrokes.
wait_for_probe_visible() {  # <target>
  local target=$1 _
  for _ in $(seq 1 75); do
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S 0 -E - 2>/dev/null \
      | grep -qF "$PROBE" && return 0
    sleep 0.2
  done
  return 1
}

CHECKED=0
SKIPPED=
UNOBSERVED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its composer is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$ROOT" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the composer probe"

  wait_settled "$target" || note "$harness $version: pane never settled; reading it anyway"

  # Record the untouched verdict now, but do not judge it until the probe below
  # proves this pane really is showing a composer.
  idle_state=$(fm_tmux_composer_state "$target")
  idle_bytes=$(composer_bytes "$target")

  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "$PROBE" 2>/dev/null \
    || fail "$harness ($version): could not type the probe text"

  if ! wait_for_probe_visible "$target"; then
    UNOBSERVED="$UNOBSERVED $harness"
    note "unverified: $harness $version never showed typed text, so it presented no composer to read (a trust or onboarding screen owns the keyboard). Its untouched verdict was '$idle_state' and is NOT asserted."
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  fi

  wait_settled "$target" || true
  typed_state=$(fm_tmux_composer_state "$target")

  # The two failure directions this guard exists to catch, asserted as
  # prohibitions so only a real misread fails. `unknown` is neither: it is the
  # deliberate refusal for a composer this backend cannot locate structurally
  # (opencode's tmux composer row carries a left-only `┃` edge, for one), and it
  # already denies both delivery confirmation and injection. It is reported as
  # unverified below rather than passed or failed.
  if [ "$typed_state" = empty ]; then
    note "$harness $version composer bytes with the probe typed:"
    composer_bytes "$target" | while IFS= read -r l; do note "  $l"; done
    fail "COMPOSER MISREAD: $harness $version has the probe text visibly in its composer, but the shared classifier reads it as an EMPTY composer. A swallowed Enter would be confirmed as delivered, and the away-mode injector would type over unsent input."
  fi
  if [ "$idle_state" = pending ]; then
    note "$harness $version untouched composer bytes:"
    printf '%s\n' "$idle_bytes" | while IFS= read -r l; do note "  $l"; done
    fail "COMPOSER DRIFT: $harness $version renders an idle, untouched composer that classifies 'pending', as if it held unsubmitted text. Delivery confirmation and the away-mode injection guard both read this verdict, so a message that landed is reported unconfirmed and every escalation is deferred. If the bytes above show a blank this release added, declare it in FM_COMPOSER_BLANKS (bin/fm-composer-lib.sh); if they show new placeholder text, it belongs in that harness's idle-placeholder pattern."
  fi

  if [ "$idle_state" = empty ] && [ "$typed_state" = pending ]; then
    note "$harness $version: untouched composer empty, probe-carrying composer pending"
    pass "composer classification: $harness $version reads empty when idle and pending when holding typed text"
    CHECKED=$((CHECKED + 1))
  else
    UNOBSERVED="$UNOBSERVED $harness"
    note "unverified: $harness $version composer is not structurally readable through this backend (untouched '$idle_state', with typed text '$typed_state'); neither misread direction fired, and both verdicts already refuse delivery confirmation and injection."
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
done

[ "$CHECKED" -gt 0 ] || fail \
  "no installed harness presented a composer this backend could read, so this run proved nothing; a pass requires at least one harness whose untouched composer read empty and whose typed composer read pending"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
if [ -n "$UNOBSERVED" ]; then
  note "unverified on this machine (composer not structurally readable):$UNOBSERVED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
