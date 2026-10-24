#!/usr/bin/env bash
# Exercise the real spawn boundary with fake GitHub and terminal responses.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-plan-gate)
# The fake pane deliberately reports a missing isolated copy: an approved gate
# must be observed before spawn reaches that unrelated isolation refusal.
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
for label in approved no-link unapproved changed newest closed pull error timeout; do
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
  case "$label" in
    approved) expect "plan gate: approved $url" ;;
    no-link) expect 'bin/fm-tasks-axi.sh update gate --title "Build <issue url>"' ;;
    unapproved|changed|newest) expect "bin/fm-plan-approve.sh $url" ;;
    closed) expect closed ;;
    pull) expect not-issue ;;
    error|timeout) expect error ;;
  esac
  if [ "$label" != approved ]; then
    expect '--plan-exception "<captain words>"'
    [ ! -e "$home/state/gate.meta" ] || fail "$label created meta"
    [ ! -e "$fakebin/.spawn-window" ] || fail "$label created endpoint"
  fi
  pass "$label gate at spawn boundary"
done
label=exception
new_case exception ''
out=$(spawn --plan-exception 'skip the plan for this task')
expect 'plan gate: EXCEPTION "skip the plan for this task"'
[ ! -s "$FM_FAKE_GH_PLAN_DIR/calls" ] || fail 'exception read GitHub'
pass 'exception skips GitHub'
label=approve
new_case approve "$url"
printf '[]\n' > "$FM_FAKE_GH_PLAN_DIR/comments.json"
out=$(PATH="$fakebin:$PATH" "$ROOT/bin/fm-plan-approve.sh" "$url" --note 'Reviewed')
expect 'https://github.com/o/r/issues/7#issuecomment-1'
out=$(spawn)
expect "plan gate: approved $url"
pass 'approval round trip'
