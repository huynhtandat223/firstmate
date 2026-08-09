#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pair-compose)
HOME_DIR=$TMP_ROOT/home
PROJECT=$TMP_ROOT/project
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
fm_git_init_commit "$PROJECT"
printf 'Implement only the accepted task.\n' > "$TMP_ROOT/task.md"
printf 'Owner: capability. No sibling work.\n' > "$TMP_ROOT/scope.md"

cat > "$FAKEBIN/brief" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1; mode=$4
mkdir -p "$FM_HOME/data/$id"
printf '# Task\n{TASK}\n\n# Scope\n{SCOPE}\n\nDelivery contract: mode=%s\n' "$mode" > "$FM_HOME/data/$id/brief.md"
SH
cat > "$FAKEBIN/spawn" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1; pane=p-driver; [ "$id" = pair-nav ] && pane=p-nav
[ "$id" != pair-nav ] || [ "${FM_FAKE_MISSING_NAV:-0}" != 1 ] || exit 7
wt=$FM_FIXTURE/$id
fm_git_init_commit() {
  git init -q "$1"
  printf x > "$1/x"
  git -C "$1" add x
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$1" checkout -qb "fm/$id"
}
fm_git_init_commit "$wt"
session=test
[ "$id" != pair-nav ] || [ "${FM_FAKE_WRONG_SESSION:-0}" != 1 ] || session=other
cat > "$FM_HOME/state/$id.meta" <<EOF
worktree=$wt
herdr_session=$session
herdr_workspace_id=old-$id
herdr_tab_id=old-$id
herdr_pane_id=$pane
EOF
[ "$id" = pair ] && : > "$FM_HOME/data/pair/driver.ack"
if [ "$id" = pair-nav ] && [ "${FM_FAKE_NO_NAV_ACK:-0}" != 1 ]; then : > "$FM_HOME/data/pair/navigator.ack"; fi
printf 'spawned %s\n' "$id"
SH
chmod +x "$FAKEBIN/brief" "$FAKEBIN/spawn"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
[ "$1" = --session ] || exit 91
shift 2
cmd="$1 $2"; shift 2
case "$cmd" in
  'pane move') exit 0 ;;
  'pane rename'|'agent rename'|'agent send') exit 0 ;;
  'pane get')
    pane=$1
    ws=pair-ws; tab=pair-tab
    [ "${FM_FAKE_WRONG_TAB:-0}" != 1 ] || { [ "$pane" = p-nav ] && tab=wrong-tab; }
    printf '{"result":{"pane":{"pane_id":"%s","workspace_id":"%s","tab_id":"%s"}}}\n' "$pane" "$ws" "$tab"
    ;;
  'pane neighbor')
    direction=$2; pane=$4; neighbor=
    if [ "$direction" = left ] && [ "$pane" = p-nav ]; then neighbor=p-driver; fi
    if [ "$direction" = right ] && [ "$pane" = p-driver ]; then neighbor=p-nav; fi
    [ "${FM_FAKE_NONADJACENT:-0}" != 1 ] || neighbor=other
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$neighbor"
    ;;
  'agent get')
    target=$1
    pane=p-driver; [ "$target" = pair-navigator ] && pane=p-nav
    [ "${FM_FAKE_DUP_AGENT:-0}" != 1 ] || pane=p-driver
    printf '{"result":{"agent":{"pane_id":"%s"}}}\n' "$pane"
    ;;
  *) exit 92 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/fm-send" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s|%s\n' "${FM_HOME:-}" "$*" >> "$FM_SEND_LOG"
[ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 23
exit 0
SH
chmod +x "$FAKEBIN/fm-send"

HELPER="$ROOT/custom-skills/paired-review/fm-pair-compose.sh"
run_pair() {
  FM_HOME="$HOME_DIR" FM_FIXTURE="$TMP_ROOT" FM_HERDR_LOG="$TMP_ROOT/herdr.log" \
    FM_PAIR_SPAWN="$FAKEBIN/spawn" FM_PAIR_BRIEF="$FAKEBIN/brief" FM_PAIR_HERDR="$FAKEBIN/herdr" \
    FM_PAIR_ACK_TIMEOUT=1 "$HELPER" --pair-id pair --project "$PROJECT" --mode direct-PR --yolo off \
    --task-file "$TMP_ROOT/task.md" --scope-file "$TMP_ROOT/scope.md" \
    --driver-harness pi --navigator-harness pi --context issue:27 --check 'focused behavior'
}
reset_pair() { rm -rf "$HOME_DIR/data/pair" "$HOME_DIR/data/pair-nav" "$HOME_DIR/state" "$TMP_ROOT/pair" "$TMP_ROOT/pair-nav"; mkdir -p "$HOME_DIR/state"; : > "$TMP_ROOT/herdr.log"; }

run_pair >/dev/null || fail "success composition failed"
jq -e '.state == "ready"' "$HOME_DIR/data/pair/recovery.json" >/dev/null || fail "ready evidence missing"
jq -e '.roles.driver.copy and .roles.navigator.copy' "$HOME_DIR/data/pair/recovery.json" >/dev/null || fail "role copy recovery evidence missing"
jq -e '.roles.driver.skill_source_revision and .roles.navigator.skill_source_revision' "$HOME_DIR/data/pair/recovery.json" >/dev/null || fail "skill revision evidence missing"
assert_present "$HOME_DIR/data/pair/ready" "barrier was not released"
assert_grep 'role=driver' "$HOME_DIR/data/pair/brief.md" "driver role fact missing"
assert_grep 'paired-review/driver/SKILL.md' "$HOME_DIR/data/pair/brief.md" "driver skill pointer missing"
assert_no_grep 'paired-review/SKILL.md' "$HOME_DIR/data/pair/brief.md" "driver reads parent skill"
assert_grep 'role=navigator' "$HOME_DIR/data/pair-nav/brief.md" "navigator role fact missing"
assert_grep 'Driver copy and branch' "$HOME_DIR/data/pair-nav/brief.md" "navigator lacks driver copy fact"
assert_grep 'current task remains implementation scope' "$HOME_DIR/data/pair-nav/brief.md" "epic scope boundary missing"
assert_grep 'agent send pair-driver PAIR READY pair;' "$TMP_ROOT/herdr.log" "driver release signal missing"
assert_grep 'agent send pair-navigator PAIR READY pair;' "$TMP_ROOT/herdr.log" "navigator release signal missing"

FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" "$HELPER" send "$HOME_DIR/data/pair/recovery.json" navigator 'MILESTONE M2' >/dev/null
FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" "$HELPER" send "$HOME_DIR/data/pair/recovery.json" driver 'STOP N3' >/dev/null
FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" "$HELPER" send "$HOME_DIR/data/pair/recovery.json" navigator 'ACK STOP N3' >/dev/null
assert_grep "$HOME_DIR|pair-nav MILESTONE M2" "$TMP_ROOT/send.log" "milestone signal not submitted via fm-send to the navigator task id"
assert_grep "$HOME_DIR|pair STOP N3" "$TMP_ROOT/send.log" "stop signal not submitted via fm-send to the driver task id"
assert_grep "$HOME_DIR|pair-nav ACK STOP N3" "$TMP_ROOT/send.log" "stop acknowledgement not submitted via fm-send to the navigator task id"
assert_no_grep 'agent send pair-navigator MILESTONE M2' "$TMP_ROOT/herdr.log" "milestone injected via Herdr instead of fm-send"
assert_no_grep 'agent send pair-driver STOP N3' "$TMP_ROOT/herdr.log" "stop injected via Herdr instead of fm-send"
assert_no_grep 'agent send pair-navigator ACK STOP N3' "$TMP_ROOT/herdr.log" "stop acknowledgement injected via Herdr instead of fm-send"

# A failed or unconfirmed fm-send result is an unsent pair signal: fail, do not retry or inject.
: > "$TMP_ROOT/send.log"
FM_FAKE_SEND_FAIL=1 FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" \
  "$HELPER" send "$HOME_DIR/data/pair/recovery.json" navigator 'UNSENT M4' >/dev/null 2>&1 \
  && fail "unconfirmed fm-send submission reported as sent"
assert_grep "$HOME_DIR|pair-nav UNSENT M4" "$TMP_ROOT/send.log" "failed submission attempt not recorded"
[ "$(grep -c 'UNSENT M4' "$TMP_ROOT/send.log")" -eq 1 ] || fail "failed pair signal was retried"
assert_no_grep 'UNSENT M4' "$TMP_ROOT/herdr.log" "unsent pair signal was injected via Herdr"
"$HELPER" finding "$HOME_DIR/data/pair/recovery.json" open N3
"$HELPER" gate "$HOME_DIR/data/pair/recovery.json" M2 abcdef1234567
jq -e '.open_findings == ["N3"] and .last_completed_gate == "M2" and .current_driver_head == "abcdef1234567"' "$HOME_DIR/data/pair/recovery.json" >/dev/null || fail "durable finding and gate recovery update missing"
"$HELPER" finding "$HOME_DIR/data/pair/recovery.json" close N3
jq -e '.open_findings == []' "$HOME_DIR/data/pair/recovery.json" >/dev/null || fail "durable finding close missing"

for scenario in missing wrongsession wrongtab nonadjacent duplicate noack; do
  reset_pair
  case "$scenario" in
    missing) export FM_FAKE_MISSING_NAV=1 ;;
    wrongsession) export FM_FAKE_WRONG_SESSION=1 ;;
    wrongtab) export FM_FAKE_WRONG_TAB=1 ;;
    nonadjacent) export FM_FAKE_NONADJACENT=1 ;;
    duplicate) export FM_FAKE_DUP_AGENT=1 ;;
    noack) export FM_FAKE_NO_NAV_ACK=1 ;;
  esac
  if run_pair >/dev/null 2>&1; then fail "$scenario failure reported ready"; fi
  [ ! -e "$HOME_DIR/data/pair/ready" ] || fail "$scenario released barrier"
  jq -e '.state == "failed" and (.failed_invariant | length > 0)' "$HOME_DIR/data/pair/recovery.json" >/dev/null || fail "$scenario recovery evidence missing"
  unset FM_FAKE_MISSING_NAV FM_FAKE_WRONG_SESSION FM_FAKE_WRONG_TAB FM_FAKE_NONADJACENT FM_FAKE_DUP_AGENT FM_FAKE_NO_NAV_ACK
 done

# Ordinary dispatch remains its own path and receives no pair facts.
reset_pair
FM_HOME="$HOME_DIR" FM_FIXTURE="$TMP_ROOT" "$FAKEBIN/spawn" ordinary "$PROJECT" >/dev/null
assert_present "$HOME_DIR/state/ordinary.meta" "ordinary dispatch metadata missing"
[ ! -e "$HOME_DIR/data/ordinary/recovery.json" ] || fail "ordinary dispatch received pair evidence"
[ ! -e "$HOME_DIR/data/ordinary/pair-log.md" ] || fail "ordinary dispatch received pair history"

pass "paired-review composition, barrier, instructions, failures, and ordinary dispatch"
