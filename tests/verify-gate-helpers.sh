#!/usr/bin/env bash
# tests/verify-gate-helpers.sh - shared fixtures for the suites that exercise the user-visible
# done gate (bin/fm-verify-gate-lib.sh): a fixture issue, a fake gh for bin/fm-acceptance.mjs, and
# the three things the gate reads - firstmate's record, the Tester's record and the deploy-verify
# ledger. The real parser reads the fixture issue; only gh is a stand-in.
#
# vg_install_gh <dir>               writes the fixture issue and a fake gh under <dir>, and
#                                   exports FM_ACCEPTANCE_GH, FM_VERIFY_GATE_GH and VG_BODY_FILE; the
#                                   fake answers the gate's commit compare by VG_ORDER (deployed heads,
#                                   oldest first; any other sha cannot be read) and VG_DIVERGED
# vg_write_records <home> <task> [none]
#                                   writes all three for a home laid out as state/ and data/ with
#                                   the Tester home at <home>/tester; every row passes, the Tester
#                                   head is the ledger's deploy sha and its digest the issue's, and firstmate approved later;
#                                   the task's endpoint record names a PR in the watched repo o/r, which
#                                   is how deploy-verify maps a task (pass `none` to leave it out)
# vg_digest                         the fixture issue's acceptance digest (fm-acceptance.mjs digest)
# vg_tester_file <home> <task>      the Tester record's path
# vg_set_row <home> <task> <id> <state> <evidence-field>
#                                   rewrites one row of the Tester record, for example A2@390 pending 'evidence: -'

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VG_ISSUE=https://github.com/o/r/issues/9
VG_SHA=1111111111111111111111111111111111111111

vg_install_gh() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat >"$dir/issue.body" <<'EOF'
## Acceptance

- [ ] A1 WHEN a user acts, THE page SHALL answer.
  - env/page: Dev 5001
  - proof: click Save
  - data: the probe row
  - mock: none
  - surface: user-visible
- [ ] A2 WHEN a user saves, THE page SHALL keep the row.
  - env/page: Dev 5001
  - proof: read the row back
  - data: the probe row
  - mock: none
  - surface: user-visible
- [ ] K3 WHEN the gate runs, THE gate SHALL refuse.
  - env/page: Dev 5001
  - proof: a test
  - data: none
  - mock: none
  - surface: internal
EOF
  cat >"$dir/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  # The gate's commit compare in the watched repo: VG_ORDER lists deployed heads oldest first.
  [ "${3:-}" = --jq ] && [ "${4:-}" = .status ] || exit 2
  pair=${2#"repos/$FM_DEPLOY_VERIFY_REPO/compare/"}
  [ "$pair" != "$2" ] || exit 1
  [ -z "${VG_DIVERGED:-}" ] || { echo diverged; exit 0; }
  pos() { local i=0 s; for s in ${VG_ORDER:-}; do [ "$s" = "$1" ] && { echo "$i"; return 0; }; i=$((i + 1)); done; return 1; }
  b=$(pos "${pair%%...*}") && h=$(pos "${pair#*...}") || exit 1
  if [ "$h" -gt "$b" ]; then echo ahead; elif [ "$h" -lt "$b" ]; then echo behind; else echo identical; fi
  exit 0
fi
[ "${1:-}" = issue ] && [ "${2:-}" = view ] || exit 2
[ -z "${VG_GH_FAIL:-}" ] || { echo 'GraphQL: Could not resolve to an Issue' >&2; exit 1; }
jq -Rs '{body: .}' "$VG_BODY_FILE"
SH
  chmod +x "$dir/gh"
  VG_BODY_FILE="$dir/issue.body"
  # The fixture issue lives in o/r, the repo deploy-verify watches in these suites.
  export FM_ACCEPTANCE_GH="$dir/gh" FM_VERIFY_GATE_GH="$dir/gh" VG_BODY_FILE FM_DEPLOY_VERIFY_REPO=o/r
}

vg_digest() { node "$ROOT/bin/fm-acceptance.mjs" digest "$VG_ISSUE"; }

vg_tester_file() {  # <home> <task>
  printf '%s/tester/data/verify/%s.md\n' "$1" "$2"
}

vg_write_records() {  # <home> <task> [none]
  local home=$1 task=$2 tf
  tf=$(vg_tester_file "$home" "$task")
  mkdir -p "$home/state" "$home/data/$task" "$home/data/deploy-verify" "$(dirname "$tf")"
  printf 'home=%s\n' "$home/tester" >"$home/state/tester.meta"
  [ "${3:-}" = none ] || printf 'pr=https://github.com/o/r/pull/5\n' >>"$home/state/$task.meta"
  grep -qx 'kind=ship' "$home/state/$task.meta" 2>/dev/null || { [ "${3:-}" = none ] || printf 'kind=ship\n' >>"$home/state/$task.meta"; }
  printf '%s\n' 'surface: user-visible' "issue: $VG_ISSUE" 'approved: firstmate 2000' >"$home/data/$task/verify.md"
  printf '{"type":"ask","round":"deploy","key":"deploy:%s:%s","task":"%s","sha":"%s"}\n' "$task" "$VG_SHA" "$task" "$VG_SHA" \
    >"$home/data/deploy-verify/ledger.jsonl"
  {
    printf '%s\n' 'surface: user-visible' "issue: $VG_ISSUE" '' '## Scenarios'
    node "$ROOT/bin/fm-acceptance.mjs" rows "$VG_ISSUE" | sed 's#| pending | evidence: -$#| pass | evidence: https://example.test/shot#'
    printf '\nverified: tester 1000 head=%s acceptance=%s\n' "$VG_SHA" "$(vg_digest)"
  } >"$tf"
}

vg_set_row() {  # <home> <task> <id> <state> <evidence-field>
  local tf
  tf=$(vg_tester_file "$1" "$2")
  awk -v id="$3" -v st="$4" -v ev="$5" 'index($0, "- " id " | ") == 1 {
      n = split($0, f, " [|] "); printf "- %s | %s | %s | %s\n", id, f[2], st, ev; next } { print }' "$tf" >"$tf.new" && mv "$tf.new" "$tf"
}
