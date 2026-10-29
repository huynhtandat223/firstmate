#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the project-rules copy in bin/fm-brief.sh (spec huynhtandat223/firstmate#200, E8c).
# PB1: every `brief:` line of data/project-rules/<repo>.md lands verbatim in `## Firstmate spec`, in file
# order, and no untagged line does. Each case scaffolds in a lab home under a temp root, never the live home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-project-rules)
LAB="$TMP_ROOT/home"
mkdir -p "$LAB/data/project-rules"

scaffold() {  # <id> <repo> [--scout]
  local id=$1 repo=$2
  shift 2
  if [ "${1:-}" = --scout ]; then
    FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$id" "$repo" --scout >/dev/null
  else
    FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$id" "$repo" --mode direct-PR >/dev/null
  fi
}

# The spec section: from the heading to the next top-level heading.
spec_of() {  # <id>
  awk '/^## Firstmate spec$/ {on=1; next} /^# / {on=0} on' "$LAB/data/$1/brief.md"
}

write_rules() {
  cat > "$LAB/data/project-rules/cfw-modules.md" <<'RULES'
# cfw-modules captain rules
brief: CI timeout stays 5 min.
An untagged rule about the right rail.
brief: Deploy from main after merge.
  brief: an indented tag is not a tag.
Say "brief:" in prose and it is still untagged.
brief: TV input only through `tv-remote` with `--expect-app` & "quotes" $HOME.
RULES
}

test_pb1_tagged_lines_are_copied_verbatim_and_untagged_are_not() {
  local spec expected
  write_rules
  scaffold pb1-ship cfw-modules
  spec=$(spec_of pb1-ship)
  expected=$(grep '^brief:' "$LAB/data/project-rules/cfw-modules.md")
  [ "$(printf '%s\n' "$spec" | grep -c '^brief:')" -eq 3 ] || fail "PB1 the spec should hold the three tagged lines: $spec"
  [ "$(printf '%s\n' "$spec" | grep '^brief:')" = "$expected" ] || fail "PB1 the tagged lines must match the file verbatim and in order: $spec"
  assert_contains "$spec" '`--expect-app` & "quotes" $HOME.' "PB1 a tagged line with quotes, ampersand and dollar must survive unchanged"
  if printf '%s\n' "$spec" | grep -qE 'right rail|indented tag|prose'; then fail "PB1 an untagged line reached the spec: $spec"; fi
  if grep -q 'right rail\|indented tag\|in prose' "$LAB/data/pb1-ship/brief.md"; then fail "PB1 an untagged line reached the brief"; fi
  pass "PB1: a cfw-modules brief holds the three brief: lines verbatim in file order and none of the untagged lines"
}

test_the_placeholder_stays_so_the_spec_is_still_filled() {
  local spec
  spec=$(spec_of pb1-ship)
  assert_contains "$spec" '{FIRSTMATE_SPEC}' "the spec placeholder must stay for firstmate to fill"
  [ "$(printf '%s\n' "$spec" | head -1)" = '{FIRSTMATE_SPEC}' ] || fail "the rules must follow the placeholder"
  pass "the {FIRSTMATE_SPEC} placeholder stays first, so a spec left unfilled is still refused at spawn"
}

test_a_scout_brief_gets_the_same_lines() {
  scaffold pb1-scout cfw-modules --scout
  [ "$(spec_of pb1-scout | grep '^brief:')" = "$(grep '^brief:' "$LAB/data/project-rules/cfw-modules.md")" ] \
    || fail "a scout brief must hold the tagged lines verbatim and in order: $(spec_of pb1-scout)"
  if spec_of pb1-scout | grep -qE 'right rail|indented tag|prose'; then fail "an untagged line reached the scout brief"; fi
  pass "a scout brief gets the same tagged lines"
}

test_other_projects_and_missing_or_untagged_files_add_nothing() {
  local before spec
  scaffold pb1-other other-project
  [ "$(spec_of pb1-other)" = '{FIRSTMATE_SPEC}' ] || fail "a project with no rules file must add nothing: $(spec_of pb1-other)"
  printf '# dms\nNo tag here.\n' > "$LAB/data/project-rules/dms.md"
  scaffold pb1-untagged dms
  [ "$(spec_of pb1-untagged)" = '{FIRSTMATE_SPEC}' ] || fail "a rules file with no tagged line must add nothing"
  if FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" pb1-slash ../project-rules/cfw-modules --mode direct-PR > "$TMP_ROOT/slash.out" 2>&1; then fail "a repo name with a slash must be refused"; fi
  assert_contains "$(cat "$TMP_ROOT/slash.out")" "contains a slash" "the refusal should say why"
  assert_absent "$LAB/data/pb1-slash/brief.md" "a refused scaffold must not write a brief"
  printf 'brief: dot-prefixed project rule.\n' > "$LAB/data/project-rules/.github.md"
  scaffold pb1-dot .github
  assert_contains "$(spec_of pb1-dot)" "brief: dot-prefixed project rule." "a dot-prefixed repo name must still get its rules"
  rm -f "$LAB/data/project-rules/.github.md"
  before=$(find "$LAB/data/project-rules" -type f | wc -l)
  [ "$before" -eq 2 ] || fail "the scaffold must not write into project-rules"
  pass "a project with no rules file or no tag adds nothing, a repo name with a slash is refused, and a dot-prefixed name works"
}

test_pb1_tagged_lines_are_copied_verbatim_and_untagged_are_not
test_the_placeholder_stays_so_the_spec_is_still_filled
test_a_scout_brief_gets_the_same_lines
test_other_projects_and_missing_or_untagged_files_add_nothing

echo "# fm-brief-project-rules.test.sh: all assertions passed"
