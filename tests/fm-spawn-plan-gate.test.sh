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
    no-link) expect 'bin/fm-tasks-axi.sh update gate --title "Build <issue url>"' ;;
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
