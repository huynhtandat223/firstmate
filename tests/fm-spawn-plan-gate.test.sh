#!/usr/bin/env bash
# Exercise the real spawn boundary with fake GitHub and terminal responses.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-plan-gate)
# Each pane reports a test-owned isolated copy; successful launches must persist
# approval evidence, while refusals must occur before any terminal is created.
new_case() {
  home="$TMP_ROOT/$1"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" gate
  fm_git_worktree "$home/projects/demo" "$home/pane" "fixture-$1"
  fakebin=$(fm_test_make_spawn_fakebin "$home/tools" claude)
  fm_test_fake_gh "$fakebin"
  touch "$home/config/dispatch-plan-gate"
  tasks-axi add gate "Build $2" --kind ship --file "$home/data/backlog.md" >/dev/null
  export FM_FAKE_GH_PLAN_DIR="$home/github"
  mkdir -p "$FM_FAKE_GH_PLAN_DIR"
  printf '{"state":"open","body":"plan"}\n' > "$FM_FAKE_GH_PLAN_DIR/issue.json"
  hash=$(printf plan | sha256sum | cut -d' ' -f1)
  printf '[{"id":1,"body":"approved: firstmate 1 body-sha256:%s"}]\n' "$hash" > "$FM_FAKE_GH_PLAN_DIR/comments.json"
}
spawn() {
  fm_test_run_spawn "$home" "$home/pane" "$fakebin" gate "$home/projects/demo" --mode direct-PR --yolo off "$@"
}
expect() {
  printf '%s\n' "$out" | grep -F -- "$1" >/dev/null || fail "$label: missing '$1': $out"
}
url=https://github.com/o/r/issues/7
for label in ${FM_PLAN_TEST_CASES:-approved no-link unapproved changed newest closed pull error timeout}; do
  new_case "$label" "$url"
  case "$label" in
    no-link) tasks-axi update gate --title Build --file "$home/data/backlog.md" >/dev/null ;;
    unapproved) printf '[]\n' > "$FM_FAKE_GH_PLAN_DIR/comments.json" ;;
    changed) printf '{"state":"open","body":"edited"}\n' > "$FM_FAKE_GH_PLAN_DIR/issue.json" ;;
    newest) jq '. + [{id:2,body:("approved: firstmate 2 body-sha256:" + ("0" * 64))}]' "$FM_FAKE_GH_PLAN_DIR/comments.json" > "$home/comments"; mv "$home/comments" "$FM_FAKE_GH_PLAN_DIR/comments.json" ;;
    closed) printf '{"state":"closed","body":"plan"}\n' > "$FM_FAKE_GH_PLAN_DIR/issue.json" ;;
    pull) printf '{"state":"open","body":"plan","pull_request":{}}\n' > "$FM_FAKE_GH_PLAN_DIR/issue.json" ;;
    error) touch "$FM_FAKE_GH_PLAN_DIR/fail" ;;
    timeout) touch "$FM_FAKE_GH_PLAN_DIR/sleep" ;;
  esac
  out=$(FM_PLAN_GATE_TIMEOUT_SECS=1 spawn)
  status=$?
  case "$label" in
    approved)
      [ "$status" = 0 ] || fail "approved launch failed: $out"
      expect "plan gate: approved $url"
      assert_grep "plan_issue=$url" "$home/state/gate.meta" 'G1 missing plan_issue'
      ;;
    no-link)
      printf -v expected_title '%q' 'Build <issue url>'
      expect "bin/fm-tasks-axi.sh update gate --title $expected_title"
      ;;
    unapproved|changed|newest) expect "bin/fm-plan-approve.sh $url" ;;
    closed) expect closed ;;
    pull) expect not-issue ;;
    error|timeout) expect error ;;
  esac
  if [ "$label" != approved ]; then
    [ "$status" != 0 ] || fail "$label did not refuse"
    expect '--plan-exception "<captain words>"'
    [ ! -e "$home/state/gate.meta" ] || fail "$label created meta"
    [ ! -e "$fakebin/.spawn-window" ] || fail "$label created endpoint"
  fi
  pass "$label gate at spawn boundary"
done
[ -z "${FM_PLAN_TEST_CASES:-}" ] || exit 0
label=exception
new_case exception ''
out=$(spawn --plan-exception 'skip the plan for this task')
status=$?
[ "$status" = 0 ] || fail "exception launch failed: $out"
encoded=$(grep '^plan_exception=' "$home/state/gate.meta")
[ "$(printf '%s' "${encoded#*=}" | base64 -d)" = 'skip the plan for this task' ] || fail 'G7 meta words differ'
body=$(tasks-axi show gate --full --file "$home/data/backlog.md")
printf '%s' "$body" | grep -F 'Plan exception (captain)' >/dev/null || fail 'G7 no body receipt'
expect 'plan gate: EXCEPTION "skip the plan for this task"'
[ ! -s "$FM_FAKE_GH_PLAN_DIR/calls" ] || fail 'exception read GitHub'
pass 'exception skips GitHub'
label=approve
new_case approve "$url"
export GH_HOST=enterprise.example.test
printf '[]\n' > "$FM_FAKE_GH_PLAN_DIR/comments.json"
out=$(PATH="$fakebin:$PATH" "$ROOT/bin/fm-plan-approve.sh" "$url" --note 'Reviewed')
expect 'https://github.com/o/r/issues/7#issuecomment-1'
marker=$(jq -r '.[0].body' "$FM_FAKE_GH_PLAN_DIR/comments.json")
marker_pattern="^approved: firstmate [0-9]+ body-sha256:$hash"$'\n''Reviewed$'
[[ $marker =~ $marker_pattern ]] || fail 'approval marker or body hash differs'
out=$(spawn)
expect "plan gate: approved $url"
pass 'approval round trip pins github.com despite GH_HOST'
unset GH_HOST

# Parser refusals do not need a project or endpoint.
for forbidden in empty batch relaunch secondmate assistance; do
  label="forbidden-$forbidden"
  new_case "$label" ''
  case "$forbidden" in
    empty) args=(gate "$home/projects/demo" --plan-exception '') ;;
    batch) args=("gate=$home/projects/demo" --plan-exception words) ;;
    relaunch) args=(gate --relaunch --plan-exception words) ;;
    secondmate) args=(gate "$home" --secondmate --plan-exception words) ;;
    assistance) args=(gate "$home" --assistance --plan-exception words) ;;
  esac
  out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" "${args[@]}")
  status=$?
  [ "$status" != 0 ] || fail "$label accepted exception"
  expect '--plan-exception'
  [ ! -s "$FM_FAKE_GH_PLAN_DIR/calls" ] || fail "$label called GitHub"
  pass "$label refuses exception before launch"
done

for label in disabled manual no-backlog pr-link multiple scout batch; do
  new_case "$label" "$url"
  case "$label" in
    disabled) rm "$home/config/dispatch-plan-gate" ;;
    manual) printf 'manual\n' > "$home/config/backlog-backend" ;;
    no-backlog) rm "$home/data/backlog.md" ;;
    pr-link) tasks-axi update gate --title 'Build https://github.com/o/r/pull/7' --file "$home/data/backlog.md" >/dev/null ;;
    multiple) tasks-axi update gate --title "Build https://github.com/o/r/issues/8 $url" --file "$home/data/backlog.md" >/dev/null ;;
    batch)
      fm_test_spawn_brief "$home" unlinked
      tasks-axi add unlinked Build --kind ship --file "$home/data/backlog.md" >/dev/null
      ;;
  esac
  case "$label" in
    scout) out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" gate "$home/projects/demo" --scout) ;;
    batch) out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" "gate=$home/projects/demo" "unlinked=$home/projects/demo" --mode direct-PR --yolo off) ;;
    *) out=$(spawn) ;;
  esac
  status=$?
  case "$label" in
    disabled)
      [ "$status" = 0 ] || fail "disabled launch failed: $out"
      [ ! -s "$FM_FAKE_GH_PLAN_DIR/calls" ] || fail 'disabled gate called GitHub'
      ;;
    manual|no-backlog|pr-link)
      [ "$status" != 0 ] || fail "$label silently passed"
      expect 'plan gate:'
      expect '--plan-exception'
      [ ! -e "$home/state/gate.meta" ] || fail "$label wrote meta"
      ;;
    multiple|scout)
      [ "$status" = 0 ] || fail "$label launch failed: $out"
      expect "plan gate: approved $url"
      assert_grep "plan_issue=$url" "$home/state/gate.meta" "$label missing approval"
      ;;
    batch)
      [ "$status" != 0 ] || fail 'batch ignored missing issue'
      expect 'batch: FAILED to spawn unlinked'
      assert_grep "plan_issue=$url" "$home/state/gate.meta" 'batch approved pair did not launch'
      [ ! -e "$home/state/unlinked.meta" ] || fail 'batch unlinked pair launched'
      ;;
  esac
  pass "$label spawn behavior"
done

# Exempt parser/recovery paths never consult the issue gate, even when enabled.
for label in exempt-relaunch exempt-secondmate exempt-assistance; do
  new_case "$label" ''
  case "$label" in
    exempt-relaunch) args=(gate --relaunch) ;;
    exempt-secondmate) args=(gate "$home" --secondmate) ;;
    exempt-assistance) args=(gate "$home" --assistance) ;;
  esac
  out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" "${args[@]}")
  [ ! -s "$FM_FAKE_GH_PLAN_DIR/calls" ] || fail "$label read GitHub"
  printf '%s' "$out" | grep -F 'plan gate:' >/dev/null && fail "$label entered gate"
  pass "$label preserves existing refusal without GitHub"
done

label=quoted-title
new_case "$label" ''
# shellcheck disable=SC2016 # Deliberately literal command substitution tests paste safety.
title='Build "quoted" $(touch '"$home/injected"')'
tasks-axi update gate --title "$title" --file "$home/data/backlog.md" >/dev/null
out=$(spawn)
command_line=$(printf '%s\n' "$out" | sed -n 's/.*link with \(bin\/fm-tasks-axi.sh update .*\); or .*/\1/p')
# Execute only the suggested command against a test-owned capture function.
# The output must preserve one literal title argument and execute no title text.
bin/fm-tasks-axi.sh() { printf '%s' "$4" > "$home/captured-title"; }
eval "$command_line"
[ ! -e "$home/injected" ] || fail 'quoted-title suggestion executed title text'
[ "$(< "$home/captured-title")" = "$title <issue url>" ] || fail 'suggested command changed title'
pass 'title repair command is safe to paste'

for label in approve-closed approve-pull approve-url; do
  new_case "$label" "$url"
  target=$url
  case "$label" in
    approve-closed) printf '{"state":"closed","body":"plan"}\n' > "$FM_FAKE_GH_PLAN_DIR/issue.json" ;;
    approve-pull) printf '{"state":"open","body":"plan","pull_request":{}}\n' > "$FM_FAKE_GH_PLAN_DIR/issue.json" ;;
    approve-url) target=https://example.com/o/r/issues/7 ;;
  esac
  out=$(PATH="$fakebin:$PATH" "$ROOT/bin/fm-plan-approve.sh" "$target" 2>&1)
  status=$?
  [ "$status" != 0 ] || fail "$label posted approval"
  [ ! -e "$FM_FAKE_GH_PLAN_DIR/calls" ] || ! grep -q POST "$FM_FAKE_GH_PLAN_DIR/calls" || fail "$label posted comment"
  pass "$label refuses approval"
done

# ---- GT1-GT8: split specs and the two-spec limit (firstmate#188) -------------

# One case home with fake GitHub, the plan gate on, and an empty call log.
gate_case() {  # <name> [<extra plan-gate-repos line>]
  home="$TMP_ROOT/$1"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" gate
  fm_git_worktree "$home/projects/demo" "$home/pane" "fixture-$1"
  fakebin=$(fm_test_make_spawn_fakebin "$home/tools" claude)
  fm_test_fake_gh "$fakebin"
  touch "$home/config/dispatch-plan-gate"
  tasks-axi add gate 'Build placeholder' --kind ship --file "$home/data/backlog.md" >/dev/null
  export FM_FAKE_GH_PLAN_DIR="$home/github"
  mkdir -p "$FM_FAKE_GH_PLAN_DIR"
  printf '[]\n' > "$FM_FAKE_GH_PLAN_DIR/comments.json"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "$home/config/plan-gate-repos"
}

issue_of() {  # <number> <state> <body with \n escapes>
  jq -n --arg state "$2" --arg body "$(printf '%b' "$3")" '{state:$state, body:$body}' > "$FM_FAKE_GH_PLAN_DIR/issue-$1.json"
}

approved_comments() {  # <number> <body with \n escapes>
  local body hash
  body=$(printf '%b' "$2")
  hash=$(printf '%s' "$body" | shasum -a 256 | cut -d' ' -f1)
  printf '[{"id":1,"body":"approved: firstmate 1 body-sha256:%s"}]\n' "$hash" > "$FM_FAKE_GH_PLAN_DIR/comments-$1.json"
}

issues_list() {  # <repo> <number> <state> <body> [more triples...]
  local repo=$1 out='[' first=1 number state body
  shift
  while [ "$#" -ge 3 ]; do
    number=$1; state=$2; body=$(printf '%b' "$3"); shift 3
    [ "$first" = 1 ] || out+=','
    first=0
    out+=$(jq -cn --argjson n "$number" --arg s "$state" --arg b "$body" '{number:$n, state:$s, body:$b}')
  done
  printf '%s]\n' "$out" > "$FM_FAKE_GH_PLAN_DIR/open-issues-${repo//\//_}.json"
}

approve_run() {  # <url>
  out=$(PATH="$fakebin:$PATH" "$ROOT/bin/fm-plan-approve.sh" "$1" 2>&1)
  status=$?
}

spec_body='## Requirements\n\nSpec text.'
parent_ticket='## Parent\n#900 (spec)\n\n## Requirements\n\nTicket.'
refused_split='error: plan gate: spec https://github.com/o/r/issues/900 has 2 open tickets in o/r (#901, #902); fold them into one ticket with a ## Steps checklist (Planner) before approval'

gate_case gt1
issue_of 901 open "$parent_ticket"
issues_list o/r 900 open "$spec_body" 901 open "$parent_ticket" 902 open "$parent_ticket"
approve_run https://github.com/o/r/issues/901
[ "$status" = 1 ] || fail "GT1 approval exit $status, want 1: $out"
printf '%s\n' "$out" | grep -F "$refused_split" >/dev/null || fail "GT1 refusal line differs: $out"
grep -q POST "$FM_FAKE_GH_PLAN_DIR/calls" && fail 'GT1 posted a comment'
pass 'GT1 a split spec refuses approval and posts nothing'

gate_case gt2 'o/other'
issue_of 900 open "$spec_body"
issue_of 901 open "$parent_ticket"
issues_list o/r 900 open "$spec_body" 901 open "$parent_ticket" 902 closed "$parent_ticket"
issues_list o/other 31 open '## Links\n\n- Parent: o/r#900 (spec).\n\n## Requirements\n\nSecond repo.'
approve_run https://github.com/o/r/issues/901
[ "$status" = 0 ] || fail "GT2 first approval exit $status: $out"
approve_run https://github.com/o/r/issues/900
[ "$status" = 0 ] || fail "GT2 spec approval exit $status: $out"
[ "$(grep -c POST "$FM_FAKE_GH_PLAN_DIR/calls")" = 2 ] || fail 'GT2 did not post exactly two markers'
pass 'GT2 one ticket per repository and its spec still approve'

gate_case gt3
gt3_table=$(mktemp "$TMP_ROOT/gt3.XXXXXX")
{
  printf '%s\t%s\n' 'https://github.com/o/r/issues/900' '## Parent\n#900 (spec)\n'
  printf '%s\t%s\n' 'https://github.com/owner/repo/issues/900' '## Parent\nowner/repo#900 (spec)\n'
  printf '%s\t%s\n' 'https://github.com/o/r/issues/900' '## Links\n\n- Parent: #900 (spec).\n'
  printf '%s\t%s\n' 'https://github.com/o/r/issues/42' '## Requirements\n\nNo parent.\n'
} > "$gt3_table"
while IFS=$'\t' read -r want body; do
  got=$(
    # shellcheck source=bin/fm-plan-gate-lib.sh
    . "$ROOT/bin/fm-plan-gate-lib.sh"
    fm_plan_gate_spec_of_body o/r 42 "$(printf '%b' "$body")"
  )
  [ "$got" = "$want" ] || fail "GT3 spec for '$body' is $got, want $want"
done < "$gt3_table"
pass 'GT3 the three parent forms and no parent resolve one canonical spec'

for label in gt4-error gt4-timeout; do
  gate_case "$label"
  issue_of 901 open "$parent_ticket"
  case "$label" in
    gt4-error) touch "$FM_FAKE_GH_PLAN_DIR/fail" ;;
    gt4-timeout) touch "$FM_FAKE_GH_PLAN_DIR/sleep" ;;
  esac
  out=$(FM_PLAN_GATE_TIMEOUT_SECS=1 PATH="$fakebin:$PATH" "$ROOT/bin/fm-plan-approve.sh" https://github.com/o/r/issues/901 2>&1)
  status=$?
  [ "$status" = 1 ] || fail "$label exit $status, want 1: $out"
  printf '%s\n' "$out" | grep -F 'GitHub read error or timeout' >/dev/null || fail "$label wording differs: $out"
  grep -q POST "$FM_FAKE_GH_PLAN_DIR/calls" && fail "$label posted a comment"
  pass "$label refuses on a repository list read error"
done

# Spawn-level cases: metas carry the specs already in flight.
ship_meta() {  # <task> <plan_issue> [<plan_spec>]
  {
    printf 'window=test:%s\nkind=ship\nplan_issue=%s\n' "$1" "$2"
    [ -z "${3:-}" ] || printf 'plan_spec=%s\n' "$3"
  } > "$home/state/$1.meta"
}

gate_case gt5
issue_of 921 open '## Parent\n#920 (spec)\n'
approved_comments 921 '## Parent\n#920 (spec)\n'
issue_of 910 open '## Requirements\n\nSpec 910.'
tasks-axi update gate --title 'Build https://github.com/o/r/issues/921' --file "$home/data/backlog.md" >/dev/null
ship_meta task-a https://github.com/o/r/issues/900 https://github.com/o/r/issues/900
ship_meta task-b https://github.com/o/r/issues/910
out=$(spawn)
status=$?
[ "$status" = 1 ] || fail "GT5 exit $status, want 1: $out"
printf '%s\n' "$out" | grep -F 'error: spec limit: 2 specs in flight (https://github.com/o/r/issues/900 by task-a, https://github.com/o/r/issues/910 by task-b)' >/dev/null \
  || fail "GT5 refusal line differs: $out"
printf '%s\n' "$out" | grep -F -- '--allow-third-spec "<captain words>"' >/dev/null || fail 'GT5 does not name the override'
[ ! -e "$home/state/gate.meta" ] || fail 'GT5 created meta'
[ ! -e "$fakebin/.spawn-window" ] || fail 'GT5 created an endpoint'
pass 'GT5 a third spec is refused before launch'

gate_case gt6
issue_of 901 open "$parent_ticket"
approved_comments 901 "$parent_ticket"
issue_of 910 open '## Requirements\n\nSpec 910.'
tasks-axi update gate --title 'Build https://github.com/o/r/issues/901' --file "$home/data/backlog.md" >/dev/null
ship_meta task-a https://github.com/o/r/issues/900 https://github.com/o/r/issues/900
ship_meta task-b https://github.com/o/r/issues/910
printf 'window=test:gt6s\nkind=scout\nplan_issue=https://github.com/o/r/issues/930\n' > "$home/state/task-s.meta"
out=$(spawn)
status=$?
[ "$status" = 0 ] || fail "GT6 exit $status: $out"
printf '%s\n' "$out" | grep -F 'spec limit: 2 in flight: https://github.com/o/r/issues/900 by task-a, https://github.com/o/r/issues/910 by task-b' >/dev/null \
  || fail "GT6 in-flight line differs: $out"
assert_grep 'plan_issue=https://github.com/o/r/issues/901' "$home/state/gate.meta" 'GT6 lost plan_issue'
assert_grep 'plan_spec=https://github.com/o/r/issues/900' "$home/state/gate.meta" 'GT6 missing plan_spec'
pass 'GT6 the same spec in flight and scout metas pass and record the spec'

gate_case gt7
issue_of 921 open '## Parent\n#920 (spec)\n'
approved_comments 921 '## Parent\n#920 (spec)\n'
issue_of 910 open '## Requirements\n\nSpec 910.'
tasks-axi update gate --title 'Build https://github.com/o/r/issues/921' --file "$home/data/backlog.md" >/dev/null
ship_meta task-a https://github.com/o/r/issues/900 https://github.com/o/r/issues/900
ship_meta task-b https://github.com/o/r/issues/910
out=$(spawn --allow-third-spec 'captain test override')
status=$?
[ "$status" = 0 ] || fail "GT7 override exit $status: $out"
printf '%s\n' "$out" | grep -F 'spec limit: OVERRIDE "captain test override"' >/dev/null || fail "GT7 override line differs: $out"
encoded=$(grep '^spec_limit_override=' "$home/state/gate.meta")
[ "$(printf '%s' "${encoded#*=}" | base64 -d)" = 'captain test override' ] || fail 'GT7 meta words differ'
override_body=$(tasks-axi show gate --full --file "$home/data/backlog.md" | sed -n 's/^  body: //p' | head -n 1 | jq -r .)
[ "$override_body" = 'Spec limit override (captain): "captain test override"' ] || fail "GT7 backlog receipt is '$override_body'"
pass 'GT7 the captain override proceeds, records the words and their receipt'

for forbidden in empty batch relaunch secondmate assistance; do
  label="gt7-forbidden-$forbidden"
  gate_case "$label" ''
  case "$forbidden" in
    empty) args=(gate "$home/projects/demo" --allow-third-spec '') ;;
    batch) args=("gate=$home/projects/demo" --allow-third-spec words) ;;
    relaunch) args=(gate --relaunch --allow-third-spec words) ;;
    secondmate) args=(gate "$home" --secondmate --allow-third-spec words) ;;
    assistance) args=(gate "$home" --assistance --allow-third-spec words) ;;
  esac
  out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" "${args[@]}")
  status=$?
  [ "$status" != 0 ] || fail "$label accepted the override"
  printf '%s\n' "$out" | grep -F -- '--allow-third-spec' >/dev/null || fail "$label wording differs: $out"
  [ ! -s "$FM_FAKE_GH_PLAN_DIR/calls" ] || fail "$label called GitHub"
  pass "$label refuses the override before launch"
done

gate_case gt8
issue_of 911 open '## Parent\n#910 (spec)\n'
issue_of 921 open '## Parent\n#920 (spec)\n'
approved_comments 911 '## Parent\n#910 (spec)\n'
approved_comments 921 '## Parent\n#920 (spec)\n'
fm_test_spawn_brief "$home" c
fm_test_spawn_brief "$home" d
tasks-axi add c 'Build https://github.com/o/r/issues/911' --kind ship --file "$home/data/backlog.md" >/dev/null
tasks-axi add d 'Build https://github.com/o/r/issues/921' --kind ship --file "$home/data/backlog.md" >/dev/null
ship_meta task-a https://github.com/o/r/issues/900 https://github.com/o/r/issues/900
out=$(fm_test_run_spawn "$home" "$home/pane" "$fakebin" "c=$home/projects/demo" "d=$home/projects/demo" --mode direct-PR --yolo off)
status=$?
[ "$status" = 1 ] || fail "GT8 exit $status, want 1: $out"
printf '%s\n' "$out" | grep -F 'error: spec limit: batch would reach 3 specs in flight' >/dev/null || fail "GT8 refusal differs: $out"
printf '%s\n' "$out" | grep -F 'c https://github.com/o/r/issues/910' >/dev/null || fail 'GT8 does not name member c and its spec'
printf '%s\n' "$out" | grep -F 'd https://github.com/o/r/issues/920' >/dev/null || fail 'GT8 does not name member d and its spec'
[ ! -e "$home/state/c.meta" ] && [ ! -e "$home/state/d.meta" ] || fail 'GT8 created a meta'
[ ! -e "$fakebin/.spawn-window" ] || fail 'GT8 created an endpoint'
pass 'GT8 a batch over the limit is refused whole before launch'
