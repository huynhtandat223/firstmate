#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), and `⟩` (muse) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Non-ASCII blank padding ------------------------------------------------
#
# Task fm-pair-delivery-false-negative-fix. Claude 2.1.226 pads its EMPTY
# composer row with U+00A0 after the `❯` glyph. The blank is not ghost text
# (luminance 153 keeps it), and every trim in this library and its callers is
# ASCII-only, so an empty composer read as `pending` - a delivery false negative
# on herdr's busy-baseline submit confirmation, which aborted a paired review
# after its release message had already landed.

test_nonascii_blank_padded_glyph_is_empty() {
  local nbsp=$'\302\240' out
  out=$(classify 0 "❯$nbsp")
  [ "$out" = empty ] || fail "bare '❯'+U+00A0 (claude's real empty composer) should be empty, got '$out'"
  out=$(classify 1 "> $nbsp")
  [ "$out" = empty ] || fail "bordered '> '+U+00A0 should be empty, got '$out'"
  out=$(classify 0 "$nbsp" "" sensitive "❯$nbsp")
  [ "$out" = empty ] || fail "a blank-only stripped row with a '❯' plain row should be empty, got '$out'"
  pass "fm_composer_classify_content: a composer padded with U+00A0 after the prompt glyph reads empty"
}

test_every_unicode_blank_reads_empty() {
  local blank out
  for blank in "${FM_COMPOSER_BLANKS[@]}"; do
    out=$(classify 0 "❯$blank")
    [ "$out" = empty ] \
      || fail "'❯' padded with the blank $(printf '%s' "$blank" | od -An -c | tr -s ' ') should be empty, got '$out'"
    out=$(classify 1 "$blank")
    [ "$out" = empty ] \
      || fail "a bordered composer holding only that blank should be empty, got '$out'"
  done
  pass "fm_composer_classify_content: every declared Unicode blank reads as an empty composer"
}

# The divergence assertion: folding blanks must not make a composer that really
# holds text read empty. Same padding byte, one visible character apart - the
# case cannot go vacuous by classifying everything empty.
test_blank_padding_does_not_swallow_real_text() {
  local nbsp=$'\302\240' empty_out text_out
  empty_out=$(classify 0 "❯$nbsp")
  text_out=$(classify 0 "❯${nbsp}PAIR READY psak-dms-kernel-canonicalization")
  [ "$empty_out" = empty ] || fail "the padded-but-empty composer should be empty, got '$empty_out'"
  [ "$text_out" = pending ] \
    || fail "blank-padded REAL text must stay pending (a swallowed Enter), got '$text_out'"
  [ "$empty_out" != "$text_out" ] \
    || fail "empty and text-carrying composers must not classify alike, both read '$empty_out'"
  text_out=$(classify 1 "${nbsp}deploy staging now${nbsp}")
  [ "$text_out" = pending ] || fail "text surrounded by blanks must stay pending, got '$text_out'"
  pass "fm_composer_classify_content: blank folding keeps real unsubmitted text pending"
}

test_blank_padding_preserves_dead_shell_refusal() {
  local nbsp=$'\302\240' out
  out=$(classify 0 ">$nbsp")
  [ "$out" = unknown ] \
    || fail "a bare shell prompt padded with U+00A0 is still a dead shell and must read unknown, got '$out'"
  pass "fm_composer_classify_content: blank folding does not turn a padded dead-shell prompt into empty"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_nonascii_blank_padded_glyph_is_empty
test_every_unicode_blank_reads_empty
test_blank_padding_does_not_swallow_real_text
test_blank_padding_preserves_dead_shell_refusal
