#!/usr/bin/env bash
# Behavior tests for bin/fm-acceptance.mjs, the one acceptance parser.
#
# The cases run the JSON CLI over fixture copies of the issue bodies that
# deploy-verify reads (tests/fixtures/fm-acceptance/cfw-<n>.body, taken with
# `gh issue view <url> --json body` on 2026-10-24) and over bodies written here.
# Each case runs against a parser copy, so the mutation proofs at the end remove
# one guard at a time and show the case that guards it go red.
# shellcheck disable=SC2016 # mutation proofs pass literal source patterns to perl
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { printf 'skip - node is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'

TMP_ROOT=$(fm_test_tmproot fm-acceptance)
FX="$ROOT/tests/fixtures/fm-acceptance"
mkdir -p "$TMP_ROOT/fakebin"

# A fake gh that answers `gh issue view <url> --json body` from FAKE_GH_BODY_FILE.
cat > "$TMP_ROOT/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = issue ] && [ "${2:-}" = view ] && [ "${4:-}" = --json ] && [ "${5:-}" = body ] || exit 2
printf '%s\n' "$3" >> "$FAKE_GH_LOG"
[ -z "${FAKE_GH_FAIL:-}" ] || { echo 'GraphQL: Could not resolve to an Issue' >&2; exit 1; }
jq -Rs '{body: .}' "$FAKE_GH_BODY_FILE"
SH
chmod +x "$TMP_ROOT/fakebin/gh"
export FM_ACCEPTANCE_GH="$TMP_ROOT/fakebin/gh" FAKE_GH_LOG="$TMP_ROOT/gh.log"

# ---- bodies -----------------------------------------------------------------

# A template-form body: every section, one scenario of each shape, every field.
tpl() {  # <scenarios-text> [<sections-order>]
  local order=${2:-"Context Requirements Definition-of-done Scenarios Mockup Links Decisions"} name
  for name in $order; do
    case "$name" in
      Scenarios) printf '## Scenarios\n\n%s\n' "$1" ;;
      Definition-of-done) printf '## Definition of done\n\nDone when the scenarios pass.\n\n' ;;
      *) printf '## %s\n\nText of %s.\n\n' "$name" "$name" ;;
    esac
  done
}
scenario() {  # <id> <surface> <page> <widths> [<skip-field>]
  local id=$1 surface=$2 page=$3 widths=$4 skip=${5:-} field
  printf -- '- [ ] %s WHEN a user acts, THE page SHALL answer.\n' "$id"
  for field in page widths controls env proof data mock surface; do
    [ "$field" != "$skip" ] || continue
    case "$field" in
      page) printf '  - page: %s\n' "$page" ;;
      widths) printf '  - widths: %s\n' "$widths" ;;
      controls) if [ "$page" = - ]; then printf '  - controls: -\n'; else printf '  - controls: button "Save"; textbox "Name"\n'; fi ;;
      env) printf '  - env: Dev 5001, SysAdmin\n' ;;
      proof) printf '  - proof: click Save and read the row back\n' ;;
      data) printf '  - data: the probe row\n' ;;
      mock) printf '  - mock: none\n' ;;
      surface) printf '  - surface: %s\n' "$surface" ;;
    esac
  done
}
FULL_SCENARIOS=$(
  scenario V1 user-visible 'home.video' '1440, 390'
  scenario V2 user-visible 'home.video-sources (draft)' '1440'
  scenario K3 internal - -
)
TEMPLATE_FULL=$(tpl "$FULL_SCENARIOS")

parse() {  # <bin-dir> [<flags>...] with the body on stdin
  local bin=$1
  shift
  node "$bin/fm-acceptance.mjs" parse - "$@"
}
rows() {  # <bin-dir> [<flags>...] with the body on stdin
  local bin=$1
  shift
  node "$bin/fm-acceptance.mjs" rows - "$@"
}
has_problem() {  # <bin-dir> <body> <fixed-text> [<flag>]: parse refuses with a problem naming the text
  local out rc
  out=$(printf '%s\n' "$2" | parse "$1" ${4:+"$4"} 2>/dev/null)
  rc=$?
  [ "$rc" -eq 1 ] || { echo "exit $rc, want 1: $out"; return 1; }
  jq -e --arg t "$3" 'any(.problems[]; contains($t))' <<<"$out" >/dev/null || { echo "no problem names '$3': $(jq -c .problems <<<"$out")"; return 1; }
}

# ---- cases: each returns 0 when the behavior holds ------------------------------

# The four issues deploy-verify reads: every scenario listed with its id, the
# legacy fields mapped, and rows expanded to scenario x width.
case_fixtures() {
  local n out ids vis
  declare -A want_ids=(
    [1530]='A1 A2'
    [1616]='V1 V2 V3 V4 V5 V6 V7 V8 V9 V10 V11 V12 V13 V14 V15 V17 V18'
    [1643]='E1 E2 E3 E4 E5 E6 E8 E11 E12 E13 E9 E10'
    [1645]='A1 A2 A3 A4 A5 A6 A7 A8 A9 A11'
  )
  declare -A want_vis=(
    [1530]='A1 A2'
    [1616]='V3 V4 V5 V6 V7 V9 V10 V11 V12 V14 V18'
    [1643]='E1 E2 E3 E4 E5 E6 E8 E11 E12 E13'
    [1645]='A1 A2 A3 A4 A5'
  )
  for n in 1530 1616 1643 1645; do
    out=$(parse "$1" < "$FX/cfw-$n.body") || { echo "cfw-$n refused: $(jq -c .problems <<<"$out")"; return 1; }
    jq -e '.schema == "fm-acceptance.v1" and .template == "legacy" and .problems == []' <<<"$out" >/dev/null || { echo "cfw-$n envelope: $(jq -c 'del(.scenarios, .sections)' <<<"$out")"; return 1; }
    ids=$(jq -r '[.scenarios[].id] | join(" ")' <<<"$out")
    [ "$ids" = "${want_ids[$n]}" ] || { echo "cfw-$n ids: $ids"; return 1; }
    vis=$(jq -r '[.scenarios[] | select(.surface == "user-visible") | .id] | join(" ")' <<<"$out")
    [ "$vis" = "${want_vis[$n]}" ] || { echo "cfw-$n user-visible: $vis"; return 1; }
    jq -e 'all(.scenarios[]; (keys_unsorted == ["id","line","done","page","draft","widths","controls","env","proof","data","mock","surface"]) and (.line | startswith("WHEN ")) and .done == false and .page == "-" and .env != "-" and .proof != "-")' <<<"$out" >/dev/null \
      || { echo "cfw-$n scenario fields: $(jq -c '.scenarios[0]' <<<"$out")"; return 1; }
    jq -e 'all(.scenarios[]; if .surface == "user-visible" then .widths == [1440, 390] else .widths == [] end)' <<<"$out" >/dev/null \
      || { echo "cfw-$n legacy widths"; return 1; }
    # Rows: one per user-visible scenario x width, in issue order.
    out=$(rows "$1" < "$FX/cfw-$n.body") || { echo "cfw-$n rows refused"; return 1; }
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = $(($(wc -w <<<"${want_vis[$n]}") * 2)) ] || { echo "cfw-$n row count"; return 1; }
    [ "$(printf '%s\n' "$out" | grep -c -E '^- [A-Z]+[0-9]+@(1440|390) \| WHEN .* \| pending \| evidence: -$')" = "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" ] \
      || { echo "cfw-$n row shape: $(printf '%s\n' "$out" | head -2)"; return 1; }
  done
  # Draft markers come from env/page, as the old matcher read them.
  out=$(parse "$1" < "$FX/cfw-1616.body")
  [ "$(jq -r '[.scenarios[] | select(.draft) | .id] | join(" ")' <<<"$out")" = 'V3 V4 V5 V6 V7 V9 V10 V11 V12 V18' ] || { echo 'cfw-1616 draft ids'; return 1; }
  out=$(parse "$1" < "$FX/cfw-1643.body")
  [ "$(jq -r '[.scenarios[] | select(.draft) | .id] | join(" ")' <<<"$out")" = 'E1 E2 E11 E12 E13' ] || { echo 'cfw-1643 draft ids'; return 1; }
  [ "$(parse "$1" < "$FX/cfw-1645.body" | jq -r '[.scenarios[] | select(.draft)] | length')" = 0 ] || { echo 'cfw-1645 has draft ids'; return 1; }
  # Legacy rows for the first user-visible line carry both default widths.
  rows "$1" < "$FX/cfw-1530.body" | head -2 | grep -q '^- A1@1440 | ' || { echo 'legacy rows do not start with width 1440'; return 1; }
}

# The template form: every field is read, rows expand and --surface all adds the
# scenarios with no width.
case_template() {
  local out r
  out=$(printf '%s\n' "$TEMPLATE_FULL" | parse "$1" --strict) || { echo "refused: $(jq -c .problems <<<"$out")"; return 1; }
  jq -e '.template == "v1" and .problems == [] and ([.sections | keys[]] | sort == (["Context","Requirements","Definition of done","Scenarios","Mockup","Links","Decisions"] | sort))' <<<"$out" >/dev/null \
    || { echo "template envelope: $(jq -c 'del(.scenarios)' <<<"$out")"; return 1; }
  jq -e '.scenarios[0] == {id: "V1", line: "WHEN a user acts, THE page SHALL answer.", done: false, page: "home.video", draft: false, widths: [1440, 390],
      controls: ["button \"Save\"", "textbox \"Name\""], env: "Dev 5001, SysAdmin", proof: "click Save and read the row back", data: "the probe row", mock: "none", surface: "user-visible"}' <<<"$out" >/dev/null \
    || { echo "scenario V1: $(jq -c '.scenarios[0]' <<<"$out")"; return 1; }
  jq -e '.scenarios[1] | .id == "V2" and .page == "home.video-sources" and .draft == true and .widths == [1440]' <<<"$out" >/dev/null || { echo "scenario V2: $(jq -c '.scenarios[1]' <<<"$out")"; return 1; }
  jq -e '.scenarios[2] | .id == "K3" and .page == "-" and .widths == [] and .controls == [] and .surface == "internal" and .draft == false' <<<"$out" >/dev/null || { echo "scenario K3: $(jq -c '.scenarios[2]' <<<"$out")"; return 1; }
  r=$(printf '%s\n' "$TEMPLATE_FULL" | rows "$1") || return 1
  [ "$r" = '- V1@1440 | WHEN a user acts, THE page SHALL answer. | pending | evidence: -
- V1@390 | WHEN a user acts, THE page SHALL answer. | pending | evidence: -
- V2@1440 | WHEN a user acts, THE page SHALL answer. | pending | evidence: -' ] || { echo "rows: $r"; return 1; }
  r=$(printf '%s\n' "$TEMPLATE_FULL" | rows "$1" --surface all | tail -1)
  [ "$r" = '- K3@- | WHEN a user acts, THE page SHALL answer. | pending | evidence: -' ] || { echo "rows --surface all: $r"; return 1; }
  r=$(printf '%s\n' "$TEMPLATE_FULL" | rows "$1" --draft)
  [ "$r" = '- V2@1440 | WHEN a user acts, THE page SHALL answer. | pending | evidence: -' ] || { echo "rows --draft: $r"; return 1; }
  # A done checkbox reads as done.
  printf '%s\n' "$(tpl "$(scenario V1 internal - - | sed 's/^- \[ \]/- [x]/')")" | parse "$1" | jq -e '.scenarios[0].done == true' >/dev/null || { echo 'checked box not read as done'; return 1; }
}

case_strict_legacy() {
  local out rc
  out=$(parse "$1" --strict < "$FX/cfw-1530.body"); rc=$?
  [ "$rc" -eq 1 ] || { echo "strict legacy exit $rc"; return 1; }
  jq -e 'any(.problems[]; contains("--strict"))' <<<"$out" >/dev/null || { echo "strict legacy problems: $(jq -c .problems <<<"$out")"; return 1; }
  # Without --strict the same body reads cleanly.
  parse "$1" < "$FX/cfw-1530.body" >/dev/null || { echo 'legacy refused without --strict'; return 1; }
}

case_duplicate_id() {
  local body
  body=$(tpl "$(scenario V1 internal - -; scenario V1 internal - -)")
  has_problem "$1" "$body" 'duplicate id' || return 1
  body=$(printf '## Acceptance\n\n- [ ] A1 first\n  - surface: internal\n- [ ] A1 again\n  - surface: internal\n')
  has_problem "$1" "$body" 'A1 (line 5): duplicate id' || return 1
}

case_user_visible_needs_page_and_widths() {
  has_problem "$1" "$(tpl "$(scenario V1 user-visible - '1440, 390')")" 'needs a page and widths' || return 1
  has_problem "$1" "$(tpl "$(scenario V1 user-visible 'home.video' -)")" 'needs a page and widths' || return 1
  # Internal scenarios carry neither.
  printf '%s\n' "$(tpl "$(scenario V1 internal - -)")" | parse "$1" >/dev/null || { echo 'internal scenario refused'; return 1; }
}

case_missing_field() {
  local f
  for f in page widths controls env proof data mock surface; do
    has_problem "$1" "$(tpl "$(scenario V1 internal - - "$f")")" "missing field $f" || return 1
  done
  has_problem "$1" "$(tpl "$(scenario V1 internal - -; printf '  - extra: nope\n')")" 'unknown field extra' || return 1
  has_problem "$1" "$(tpl "$(scenario V1 internal - -; printf '  - env: again\n')")" 'field env given twice' || return 1
  has_problem "$1" "$(tpl "$(scenario V1 sideways - -)")" 'not user-visible or internal' || return 1
  has_problem "$1" "$(tpl "$(scenario V1 user-visible p '1440, wide')")" 'widths is not' || return 1
  # A legacy scenario still needs its surface.
  has_problem "$1" "$(printf '## Acceptance\n\n- [ ] A1 no surface\n  - env/page: x\n')" 'missing field surface' || return 1
}

# Legacy issues are read as the old matcher read them, so none that read before is
# newly refused: a surface value is read by its word, a checklist item with no id
# is not a scenario, and --strict refuses what the template would.
case_legacy_leniency() {
  local body out
  body=$(printf '## Acceptance\n\n- [ ] Plain item with no id\n- [ ] A1 WHEN a, THE b SHALL c.\n  - env/page: x (draft)\n  - surface: user-visible.\n- [ ] A2 WHEN a, THE b SHALL c.\n  - env/page: y\n  - surface: internal. Nothing to see.\n')
  out=$(printf '%s\n' "$body" | parse "$1") || { echo "legacy body refused: $(jq -c .problems <<<"$out")"; return 1; }
  jq -e '[.scenarios[] | [.id, .surface, .draft, (.widths | length)]] == [["A1","user-visible",true,2],["A2","internal",false,0]]' <<<"$out" >/dev/null || { echo "legacy scenarios: $(jq -c .scenarios <<<"$out")"; return 1; }
  has_problem "$1" "$body" 'line 3: checklist item has no id' '--strict' || return 1
}

# The template names the order of the eight fields; a scenario that shuffles them is refused.
case_field_order() {
  local shuffled
  shuffled=$(scenario V1 internal - - | awk '/^  - env:/ { e = $0; next } /^  - proof:/ { print; print e; next } { print }')
  has_problem "$1" "$(tpl "$shuffled")" 'V1 (line' || return 1
  has_problem "$1" "$(tpl "$shuffled")" 'fields are out of order' || return 1
  # The unshuffled control reads clean, and legacy field order stays free.
  printf '%s\n' "$(tpl "$(scenario V1 internal - -)")" | parse "$1" --strict >/dev/null || { echo 'the ordered control was refused'; return 1; }
  printf '## Acceptance\n\n- [ ] A1 WHEN a, THE b SHALL c.\n  - surface: internal\n  - env/page: x\n' | parse "$1" >/dev/null || { echo 'legacy field order was refused'; return 1; }
}

case_bad_id() {
  has_problem "$1" "$(tpl '- [ ] lowercase1 WHEN x, THE y SHALL z.')" 'no id right after the checkbox' || return 1
  has_problem "$1" "$(tpl '- [ ] WHEN there is no id, THE y SHALL z.')" 'no id right after the checkbox' || return 1
  has_problem "$1" "$(tpl '- [ ] A1b WHEN x.')" 'no id right after the checkbox' || return 1
}

case_sections() {
  local out
  has_problem "$1" "$(tpl "$FULL_SCENARIOS" 'Context Requirements Definition-of-done Scenarios Mockup Links')" 'missing section ## Decisions' || return 1
  has_problem "$1" "$(tpl "$FULL_SCENARIOS" 'Context Requirements Scenarios Definition-of-done Mockup Links Decisions')" 'out of order' || return 1
  has_problem "$1" "$(tpl "$FULL_SCENARIOS" 'Context Context Requirements Definition-of-done Scenarios Mockup Links Decisions')" 'appears 2 times' || return 1
  # An issue with no acceptance section has no scenarios, and only --strict refuses it.
  out=$(printf '## Context\n\nA body with no scenarios section.\n' | parse "$1") || { echo 'a body with no acceptance section was refused without --strict'; return 1; }
  jq -e '.template == "legacy" and .scenarios == [] and .problems == []' <<<"$out" >/dev/null || { echo "no-section body: $out"; return 1; }
  printf '## Context\n\nA body with no scenarios section.\n' | parse "$1" --strict >/dev/null && { echo 'a body with no scenarios section passed --strict'; return 1; }
  has_problem "$1" "$(tpl '')" 'holds no scenario' || return 1
  # A heading of another name between the seven is not a section the harness reads.
  printf '%s\n' "$(tpl "$FULL_SCENARIOS" 'Context Requirements Definition-of-done Scenarios Mockup Links Decisions'; printf '## Appendix\n\n- [ ] Z9 not a scenario\n')" \
    | parse "$1" | jq -e '.problems == [] and ([.scenarios[].id] == ["V1","V2","K3"])' >/dev/null || { echo 'another section was read'; return 1; }
}

# Headings and checklist lines inside fenced code blocks are ignored, and only a
# `## ` at the start of a line is a section.
case_fences_and_headings() {
  local body out
  body=$(tpl "$FULL_SCENARIOS" | awk '
    /^## Requirements/ { print; print ""; print "```"; print "## Scenarios"; print "- [ ] Q1 WHEN a fenced line, THE parser SHALL ignore it."; print "  - surface: internal"; print "```"; print ""; print "~~~md"; print "## Context"; print "~~~"; next }
    { print }')
  out=$(printf '%s\n' "$body" | parse "$1" --strict) || { echo "fenced body refused: $(jq -c .problems <<<"$out")"; return 1; }
  jq -e '[.scenarios[].id] == ["V1","V2","K3"] and (.sections.Requirements.body | contains("Q1"))' <<<"$out" >/dev/null || { echo "fenced lines were read: $(jq -c '[.scenarios[].id]' <<<"$out")"; return 1; }
  # `### Scenarios` and an indented `## Scenarios` open no section.
  body=$(printf '## Context\n\nx\n\n### Scenarios\n\n- [ ] Q1 WHEN a, THE b SHALL c.\n\n  ## Scenarios\n')
  out=$(printf '%s\n' "$body" | parse "$1")
  jq -e '.template == "legacy"' <<<"$out" >/dev/null || { echo 'an indented or deeper heading opened Scenarios'; return 1; }
  # A fence that never closes hides the rest of the body.
  body=$(tpl "$FULL_SCENARIOS"; printf '```\n## Extra\n- [ ] Q1 WHEN a, THE b SHALL c.\n')
  printf '%s\n' "$body" | parse "$1" | jq -e '[.scenarios[].id] == ["V1","V2","K3"]' >/dev/null || { echo 'an open fence leaked lines'; return 1; }
}

# An issue URL is read with gh; a failed read is exit 2 and its error.
case_url() {
  local out rc err
  printf '%s\n' "$TEMPLATE_FULL" > "$TMP_ROOT/body.md"
  export FAKE_GH_BODY_FILE="$TMP_ROOT/body.md"
  : > "$FAKE_GH_LOG"
  out=$(node "$1/fm-acceptance.mjs" rows https://github.com/o/r/issues/7 2>&1) || { echo "url rows: $out"; return 1; }
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] || { echo "url rows: $out"; return 1; }
  [ "$(cat "$FAKE_GH_LOG")" = 'https://github.com/o/r/issues/7' ] || { echo "gh saw: $(cat "$FAKE_GH_LOG")"; return 1; }
  node "$1/fm-acceptance.mjs" parse https://github.com/o/r/issues/7 | jq -e '.template == "v1"' >/dev/null || { echo 'url parse'; return 1; }
  err=$(FAKE_GH_FAIL=1 node "$1/fm-acceptance.mjs" parse https://github.com/o/r/issues/7 2>&1 >/dev/null); rc=$?
  [ "$rc" -eq 2 ] || { echo "read failure exit $rc"; return 1; }
  case "$err" in *'could not read https://github.com/o/r/issues/7'*'Could not resolve'*) ;; *) echo "read failure message: $err"; return 1 ;; esac
  err=$(FM_ACCEPTANCE_GH="$TMP_ROOT/absent-gh" node "$1/fm-acceptance.mjs" rows https://github.com/o/r/issues/7 2>&1 >/dev/null); rc=$?
  [ "$rc" -eq 2 ] || { echo "missing gh exit $rc"; return 1; }
  node "$1/fm-acceptance.mjs" parse >/dev/null 2>&1; [ $? -eq 2 ] || { echo 'no source was not exit 2'; return 1; }
  node "$1/fm-acceptance.mjs" bogus - >/dev/null 2>&1 </dev/null; [ $? -eq 2 ] || { echo 'unknown command was not exit 2'; return 1; }
}

# `digest` is one stable hash of the parsed scenarios: a change to any scenario field moves it,
# the checkbox and the sections around the scenarios do not.
case_digest() {
  local base d1 other field
  digest() { printf '%s\n' "$2" | node "$1/fm-acceptance.mjs" digest -; }
  d1=$(digest "$1" "$TEMPLATE_FULL") || { echo 'digest refused a good issue'; return 1; }
  [ "$(printf '%s' "$d1" | tr -d '0-9a-f')" = '' ] && [ "${#d1}" = 64 ] || { echo "digest shape: $d1"; return 1; }
  [ "$(digest "$1" "$TEMPLATE_FULL")" = "$d1" ] || { echo 'digest is not stable across runs'; return 1; }
  base=$TEMPLATE_FULL
  for field in 'button "Save"/button "Save2"' 'click Save and read/click Save twice and read' 'the probe row/the other row' 'mock: none/mock: a fake' \
    'Dev 5001, SysAdmin/Dev 5002, SysAdmin' 'page: home.video/page: home.audio' 'widths: 1440, 390/widths: 1440' 'THE page SHALL answer/THE page SHALL stay'; do
    other=$(printf '%s\n' "$base" | sed "s/${field%%/*}/${field#*/}/")
    [ "$other" != "$base" ] || { echo "the edit '$field' changed nothing"; return 1; }
    [ "$(digest "$1" "$other")" != "$d1" ] || { echo "digest ignores the edit '$field'"; return 1; }
  done
  other=$(printf '%s\n' "$base" | sed 's/^- \[ \] V1/- [x] V1/')
  [ "$other" != "$base" ] && [ "$(digest "$1" "$other")" = "$d1" ] || { echo 'digest moved with the checkbox'; return 1; }
  other=$(printf '%s\n' "$base" | sed 's/^Text of Decisions\./Another decision./')
  [ "$other" != "$base" ] && [ "$(digest "$1" "$other")" = "$d1" ] || { echo 'digest moved with a section around the scenarios'; return 1; }
  other=$(tpl "$FULL_SCENARIOS"$'\n'"$(scenario V9 user-visible - -)")
  [ "$(digest "$1" "$other")" != "$d1" ] || { echo 'digest ignores an added scenario'; return 1; }
  d1=$(printf '%s\n' "$(tpl "$(scenario V1 user-visible - -)")" | node "$1/fm-acceptance.mjs" digest - 2>/dev/null); [ $? -eq 1 ] && [ -z "$d1" ] || { echo 'digest of a refused issue'; return 1; }
}

# `rows` prints nothing for a refused issue and says why on stderr.
case_rows_refusal() {
  local out err rc
  out=$(printf '%s\n' "$(tpl "$(scenario V1 user-visible - -)")" | rows "$1" 2>"$TMP_ROOT/err"); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$out" ] || { echo "rows on a refused issue: exit $rc, out '$out'"; return 1; }
  err=$(<"$TMP_ROOT/err")
  case "$err" in *'needs a page and widths'*) ;; *) echo "rows refusal message: $err"; return 1 ;; esac
}

# The module is importable by the board and the gate.
case_import() {
  local out
  out=$(node --input-type=module -e "
    import { parseIssue, rows } from '$1/fm-acceptance.mjs';
    const p = parseIssue(process.argv[1]);
    console.log(JSON.stringify([p.template, p.scenarios.length, rows(p).length]));
  " "$TEMPLATE_FULL" 2>&1) || { echo "import: $out"; return 1; }
  [ "$out" = '["v1",3,3]' ] || { echo "import result: $out"; return 1; }
}

CASES="fixtures template strict_legacy legacy_leniency field_order duplicate_id user_visible_needs_page_and_widths missing_field bad_id sections fences_and_headings url rows_refusal digest import"

# ---- real parser ------------------------------------------------------------

for c in $CASES; do
  out=$(case_"$c" "$ROOT/bin" 2>&1) || fail "case $c failed on the real parser: $out"
  pass "fm-acceptance $c"
done

# ---- mutation proofs: remove one guard, the case guarding it goes red ------------

MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp "$ROOT/bin/fm-acceptance.mjs" "$TMP_ROOT/parser.orig"
PARSER="$MBIN/fm-acceptance.mjs"

mutate() {  # <label> <case> <perl-substitution>
  cp "$TMP_ROOT/parser.orig" "$PARSER"
  perl -0pi -e "$3" "$PARSER"
  cmp -s "$TMP_ROOT/parser.orig" "$PARSER" && fail "mutation '$1' changed nothing"
  if out=$(case_"$2" "$MBIN" 2>&1); then
    fail "removing the guard '$1' left case $2 green"
  fi
  pass "guard '$1' is needed: case $2 goes red without it"
}

mutate 'a duplicate id is refused' duplicate_id 's/seen\.has\(scenario\.id\)/false/'
mutate 'a user-visible scenario needs page and widths' user_visible_needs_page_and_widths \
  "s/surface === 'user-visible' && \\(page === '-' \\|\\| widths\\.length === 0\\)/false/"
mutate 'the fields keep the template order' field_order 's/if \(given\.join\(\) !== ordered\.join\(\)\)/if (false)/'
mutate 'every field must be present' missing_field 's/if \(missing\.length\)/if (false)/'
mutate 'an unknown field is refused' missing_field "s/if \\(template === 'v1'\\) problems\\.push\\(\`\\\$\\{where\\}: unknown field/if (false) problems.push(\`\\\${where}: unknown field/"
mutate 'a field given twice is refused' missing_field 's/if \(f\.name in fields\)/if (false)/'
mutate 'surface is user-visible or internal' missing_field "s/surface !== 'user-visible' && surface !== 'internal'/false/"
mutate 'widths are numbers' missing_field 's/widths\.some\(\(w\) => !\/\^\[0-9\]\+\$\/\.test\(w\)\)/false/'
mutate 'an id must follow the checkbox' bad_id 's/if \(!idMatch\) \{/if (false) {/'
mutate 'the id is capital letters then digits' bad_id 's/\[A-Z\]\+\[0-9\]\+\)\(\?=/[A-Za-z]+[0-9]*)(?=/'
mutate 'a missing section is refused' sections 's/if \(found\.length === 0\) \{/if (found.length === 0 \&\& false) {/'
mutate 'sections keep their order' sections 's/if \(index < previous\)/if (false)/'
mutate 'a repeated section is refused' sections 's/if \(found\.length > 1\)/if (false)/'
mutate 'an empty Scenarios section is refused' sections "s/if \\(template === 'v1' && scenarios\\.length === 0\\)/if (false)/"
mutate 'strict refuses legacy' strict_legacy 's/if \(strict\) problems/if (false) problems/'
mutate 'a legacy surface is read by its word' legacy_leniency "s/template === 'legacy' && surface !== ''/false/"
mutate 'a legacy checklist item with no id is not a scenario' legacy_leniency "s/if \\(template === 'v1' \\|\\| strict\\) problems\\.push\\(\\\`line/if (true) problems.push(\\\`line/"
mutate 'fenced lines are ignored' fences_and_headings 's/fence = \{ char: m\[1\]\[0\], length: m\[1\]\.length \};/;/'
mutate 'only a heading at the start of a line is a section' fences_and_headings 's/\/\^## \(\.\*\?\)\[ \\t\]\*\$\//\/^[ \\t#]*## (.*?)[ \\t]*\$\//'
mutate 'a legacy scenario gets the default widths' fixtures 's/\? \[\.\.\.LEGACY_WIDTHS\] : \[\]/? [] : []/'
mutate 'draft comes from the page' template "s/draft = \\/\\\\\\(draft\\\\\\)\\/\\.test\\(rawPage\\)/draft = false/"
mutate 'a failed read is exit 2' url 's/process\.stderr\.write\(`error: \$\{error\.message\}\\n`\);\n    return 2;/process.stderr.write(`error: \${error.message}\\n`);\n    return 1;/'
mutate 'rows refuse a refused issue' rows_refusal 's/else if \(parsed\.problems\.length === 0\) \{/else if (true) {/'
mutate 'the checkbox is not part of the digest' digest 's/\(\{ done, \.\.\.rest \}\) => rest/(scenario) => scenario/'
mutate 'the digest covers every scenario field' digest 's/\(\{ done, \.\.\.rest \}\) => rest/({ done, id }) => ({ id })/'
pass 'every guarded behavior has a red mutation proof'
