#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pair-compose)
HOME_DIR=$TMP_ROOT/home
PROJECT=$TMP_ROOT/project
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
fm_git_init_commit "$PROJECT"
printf 'Implement only the accepted task.\n' > "$TMP_ROOT/task.md"
printf 'Owner: capability. No sibling work.\n' > "$TMP_ROOT/scope.md"

HERDR_STATE=$TMP_ROOT/herdr-state.json

cat > "$FAKEBIN/brief" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1; mode=$4
mkdir -p "$FM_HOME/data/$id"
printf '# Task\n{TASK}\n\n# Scope\n{SCOPE}\n\nDelivery contract: mode=%s\n' "$mode" > "$FM_HOME/data/$id/brief.md"
SH

# Fixture control of the fake Herdr session: seed a session that already hosts
# one unrelated agent, and register a launched role pane in it.
cat > "$FAKEBIN/herdr-fixture" <<'PY'
#!/usr/bin/env python3
import json, os, sys

state_path = os.environ["FM_HERDR_STATE"]

def load():
    with open(state_path) as f:
        return json.load(f)

def save(state):
    with open(state_path, "w") as f:
        json.dump(state, f)

cmd = sys.argv[1]
if cmd == "seed":
    save({"seq": 0, "panes": [{
        "pane_id": "decoy", "workspace_id": "wD", "tab_id": "wD:t1",
        "name": None, "label": None,
        "cwd": "/nonexistent/decoy", "foreground_cwd": "/nonexistent/decoy"}]})
elif cmd == "register":
    pane_id, copy = sys.argv[2], sys.argv[3]
    state = load()
    state["seq"] += 1
    workspace = "w%d" % state["seq"]
    state["panes"].append({
        "pane_id": pane_id, "workspace_id": workspace, "tab_id": workspace + ":t1",
        "name": None, "label": None,
        "cwd": os.environ.get("FM_FAKE_LAUNCH_CWD", "/nonexistent/project"),
        "foreground_cwd": copy})
    save(state)
else:
    sys.exit("unknown fixture command: " + cmd)
PY

# Fake Herdr, faithful to the real CLI's identity model: a pane id is positional
# and is REASSIGNED on every move, an agent name is the stable role identity,
# and `pane neighbor` reports the adjacent pane in `neighbor_pane_id` while
# `pane_id` echoes the query.
cat > "$FAKEBIN/herdr" <<'PY'
#!/usr/bin/env python3
import json, os, sys

argv = sys.argv[1:]
with open(os.environ["FM_HERDR_LOG"], "a") as log:
    log.write(" ".join(argv) + "\n")
if len(argv) < 4 or argv[0] != "--session":
    sys.exit(91)
group, cmd, args = argv[2], argv[3], argv[4:]

state_path = os.environ["FM_HERDR_STATE"]
with open(state_path) as f:
    state = json.load(f)

def save():
    with open(state_path, "w") as f:
        json.dump(state, f)

def find(pane_id):
    for pane in state["panes"]:
        if pane["pane_id"] == pane_id:
            return pane
    return None

def next_id(prefix):
    state["seq"] += 1
    return "%s%d" % (prefix, state["seq"])

def detach(pane):
    state["panes"] = [p for p in state["panes"] if p is not pane]

def index_of(panes, pane):
    return next(i for i, p in enumerate(panes) if p is pane)

def info(pane):
    return {k: pane[k] for k in
            ("pane_id", "workspace_id", "tab_id", "name", "label", "cwd", "foreground_cwd")}

def emit(result):
    print(json.dumps({"result": result}))

def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default

if (group, cmd) == ("agent", "list"):
    agents = []
    for pane in state["panes"]:
        agent = info(pane)
        agent["agent_status"] = "working"
        if os.environ.get("FM_FAKE_COPY_DRIFT") == "1" and (agent["name"] or "").endswith("-navigator"):
            agent["cwd"] = "/nonexistent/other-copy"
            agent["foreground_cwd"] = "/nonexistent/other-copy"
        agents.append(agent)
    emit({"type": "agent_list", "agents": agents})
elif (group, cmd) == ("agent", "rename"):
    target, name = args[0], args[1]
    pane = find(target)
    if pane is None:
        sys.exit(93)
    if name == "--clear":
        pane["name"] = None
    elif os.environ.get("FM_FAKE_LOST_NAME") == "1" and name.endswith("-navigator"):
        pass
    else:
        pane["name"] = name
        if os.environ.get("FM_FAKE_DUP_NAME") == "1" and name.endswith("-navigator"):
            decoy = find("decoy")
            if decoy is not None:
                decoy["name"] = name
    save()
    emit({"type": "agent_info", "agent": info(pane)})
elif (group, cmd) == ("pane", "get"):
    pane = find(args[0])
    if pane is None:
        sys.exit(94)
    emit({"type": "pane_info", "pane": info(pane)})
elif (group, cmd) == ("pane", "rename"):
    pane = find(args[0])
    if pane is None:
        sys.exit(94)
    pane["label"] = args[1]
    save()
    emit({"type": "pane_info", "pane": info(pane)})
elif (group, cmd) == ("pane", "move"):
    pane = find(args[0])
    if pane is None:
        sys.exit(94)
    previous = pane["pane_id"]
    pane["pane_id"] = next_id("p")
    detach(pane)
    if "--new-workspace" in args or os.environ.get("FM_FAKE_WRONG_TAB") == "1":
        workspace = next_id("w")
        pane["workspace_id"] = workspace
        pane["tab_id"] = workspace + ":t1"
        state["panes"].append(pane)
    else:
        target = find(opt("--target-pane"))
        if target is None:
            sys.exit(95)
        pane["workspace_id"] = target["workspace_id"]
        pane["tab_id"] = opt("--tab")
        at = index_of(state["panes"], target) + 1
        if os.environ.get("FM_FAKE_NONADJACENT") == "1":
            state["panes"].insert(at, {
                "pane_id": next_id("p"), "workspace_id": target["workspace_id"],
                "tab_id": target["tab_id"], "name": None, "label": None,
                "cwd": "/nonexistent/filler", "foreground_cwd": "/nonexistent/filler"})
            at += 1
        state["panes"].insert(at, pane)
    save()
    emit({"type": "pane_move", "previous_pane_id": previous, "pane": info(pane)})
elif (group, cmd) == ("pane", "neighbor"):
    direction = opt("--direction")
    pane = find(opt("--pane"))
    if pane is None:
        sys.exit(96)
    siblings = [p for p in state["panes"] if p["tab_id"] == pane["tab_id"]]
    at = index_of(siblings, pane)
    neighbor = None
    if direction == "left" and at > 0:
        neighbor = siblings[at - 1]["pane_id"]
    if direction == "right" and at + 1 < len(siblings):
        neighbor = siblings[at + 1]["pane_id"]
    result = {"pane_id": pane["pane_id"], "direction": direction,
              "layout": {"tab_id": pane["tab_id"]}}
    if neighbor is not None:
        result["neighbor_pane_id"] = neighbor
    emit({"type": "pane_neighbor", "neighbor": result})
else:
    sys.exit(92)
PY

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
"$FM_FAKE_FIXTURE" register "$pane" "$(cd "$wt" && pwd -P)"
# Herdr may move a pane straight after launch, which reassigns its id. The
# recorded herdr_pane_id is then a stale hint that no longer names any pane.
[ "${FM_FAKE_STALE_PANE:-0}" != 1 ] || pane=stale-$pane
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

cat > "$FAKEBIN/fm-send" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s|%s\n' "${FM_HOME:-}" "$*" >> "$FM_SEND_LOG"
[ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 23
exit 0
SH
chmod +x "$FAKEBIN/brief" "$FAKEBIN/spawn" "$FAKEBIN/herdr" "$FAKEBIN/herdr-fixture" "$FAKEBIN/fm-send"

export FM_HERDR_STATE="$HERDR_STATE"
export FM_HERDR_LOG="$TMP_ROOT/herdr.log"
export FM_FAKE_FIXTURE="$FAKEBIN/herdr-fixture"

EVIDENCE=$HOME_DIR/data/pair/recovery.json
HELPER="$ROOT/custom-skills/paired-review/fm-pair-compose.sh"
herdr_cli() { "$FAKEBIN/herdr" --session test "$@"; }
role_field() { herdr_cli agent list | jq -r --arg name "$1" --arg field "$2" '.result.agents[] | select(.name == $name) | .[$field]'; }
generations() { jq -r '.topology_generations | length' "$EVIDENCE"; }

run_pair() {
  FM_HOME="$HOME_DIR" FM_FIXTURE="$TMP_ROOT" \
    FM_PAIR_SPAWN="$FAKEBIN/spawn" FM_PAIR_BRIEF="$FAKEBIN/brief" FM_PAIR_HERDR="$FAKEBIN/herdr" \
    FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" \
    FM_PAIR_ACK_TIMEOUT=1 "$HELPER" --pair-id pair --project "$PROJECT" --mode direct-PR --yolo off \
    --task-file "$TMP_ROOT/task.md" --scope-file "$TMP_ROOT/scope.md" \
    --driver-harness pi --navigator-harness pi --context issue:27 --check 'focused behavior'
}
reset_pair() {
  rm -rf "$HOME_DIR/data/pair" "$HOME_DIR/data/pair-nav" "$HOME_DIR/state" "$TMP_ROOT/pair" "$TMP_ROOT/pair-nav"
  mkdir -p "$HOME_DIR/state"
  "$FAKEBIN/herdr-fixture" seed
  : > "$FM_HERDR_LOG"
  : > "$TMP_ROOT/send.log"
}

reset_pair
run_pair >/dev/null || fail "success composition failed"
jq -e '.state == "ready"' "$EVIDENCE" >/dev/null || fail "ready evidence missing"
jq -e '.roles.driver.copy and .roles.navigator.copy' "$EVIDENCE" >/dev/null || fail "role copy recovery evidence missing"
jq -e '.roles.driver.skill_source_revision and .roles.navigator.skill_source_revision' "$EVIDENCE" >/dev/null || fail "skill revision evidence missing"
assert_present "$HOME_DIR/data/pair/ready" "barrier was not released"
assert_grep 'role=driver' "$HOME_DIR/data/pair/brief.md" "driver role fact missing"
assert_grep 'paired-review/driver/SKILL.md' "$HOME_DIR/data/pair/brief.md" "driver skill pointer missing"
assert_no_grep 'paired-review/SKILL.md' "$HOME_DIR/data/pair/brief.md" "driver reads parent skill"
assert_grep 'role=navigator' "$HOME_DIR/data/pair-nav/brief.md" "navigator role fact missing"
assert_grep 'Driver copy and branch' "$HOME_DIR/data/pair-nav/brief.md" "navigator lacks driver copy fact"
assert_grep 'current task remains implementation scope' "$HOME_DIR/data/pair-nav/brief.md" "epic scope boundary missing"
assert_grep "$HOME_DIR|pair PAIR READY pair;" "$TMP_ROOT/send.log" "driver readiness release not submitted via fm-send"
assert_grep "$HOME_DIR|pair-nav PAIR READY pair;" "$TMP_ROOT/send.log" "navigator readiness release not submitted via fm-send"
assert_no_grep 'agent send' "$FM_HERDR_LOG" "raw herdr agent send used for a delivery path"
assert_no_grep 'pane send-text' "$FM_HERDR_LOG" "raw pane send-text used for a delivery path"

# Composition's own moves reassign both pane ids, so the published topology must
# be the panes the roles occupy NOW, never the ones they were launched with.
LAUNCH_DRIVER_PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/pair.meta")
LAUNCH_NAV_PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/pair-nav.meta")
jq -e --arg dp "$LAUNCH_DRIVER_PANE" --arg np "$LAUNCH_NAV_PANE" \
  '(.topology_generations | last) | .driver_pane != $dp and .navigator_pane != $np' "$EVIDENCE" >/dev/null \
  || fail "topology generation recorded the launch pane ids instead of the current panes"
jq -e --arg dp "$(role_field pair-driver pane_id)" --arg np "$(role_field pair-navigator pane_id)" \
  '(.topology_generations | last) | .driver_pane == $dp and .navigator_pane == $np' "$EVIDENCE" >/dev/null \
  || fail "topology generation does not match the live role panes"

FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" "$HELPER" send "$EVIDENCE" navigator 'MILESTONE M2' >/dev/null
FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" "$HELPER" send "$EVIDENCE" driver 'STOP N3' >/dev/null
FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" "$HELPER" send "$EVIDENCE" navigator 'ACK STOP N3' >/dev/null
assert_grep "$HOME_DIR|pair-nav MILESTONE M2" "$TMP_ROOT/send.log" "milestone signal not submitted via fm-send to the navigator task id"
assert_grep "$HOME_DIR|pair STOP N3" "$TMP_ROOT/send.log" "stop signal not submitted via fm-send to the driver task id"
assert_grep "$HOME_DIR|pair-nav ACK STOP N3" "$TMP_ROOT/send.log" "stop acknowledgement not submitted via fm-send to the navigator task id"
assert_no_grep 'agent send pair-navigator MILESTONE M2' "$FM_HERDR_LOG" "milestone injected via Herdr instead of fm-send"
assert_no_grep 'agent send pair-driver STOP N3' "$FM_HERDR_LOG" "stop injected via Herdr instead of fm-send"
assert_no_grep 'agent send pair-navigator ACK STOP N3' "$FM_HERDR_LOG" "stop acknowledgement injected via Herdr instead of fm-send"

# A failed or unconfirmed fm-send result is an unsent pair signal: fail, do not retry or inject.
: > "$TMP_ROOT/send.log"
FM_FAKE_SEND_FAIL=1 FM_PAIR_SEND="$FAKEBIN/fm-send" FM_SEND_LOG="$TMP_ROOT/send.log" \
  "$HELPER" send "$EVIDENCE" navigator 'UNSENT M4' >/dev/null 2>&1 \
  && fail "unconfirmed fm-send submission reported as sent"
assert_grep "$HOME_DIR|pair-nav UNSENT M4" "$TMP_ROOT/send.log" "failed submission attempt not recorded"
[ "$(grep -c 'UNSENT M4' "$TMP_ROOT/send.log")" -eq 1 ] || fail "failed pair signal was retried"
assert_no_grep 'UNSENT M4' "$FM_HERDR_LOG" "unsent pair signal was injected via Herdr"
"$HELPER" finding "$EVIDENCE" open N3
"$HELPER" gate "$EVIDENCE" M2 abcdef1234567
jq -e '.open_findings == ["N3"] and .last_completed_gate == "M2" and .current_driver_head == "abcdef1234567"' "$EVIDENCE" >/dev/null || fail "durable finding and gate recovery update missing"
"$HELPER" finding "$EVIDENCE" close N3
jq -e '.open_findings == []' "$EVIDENCE" >/dev/null || fail "durable finding close missing"

# --- recovery after Herdr moves a live pair ---------------------------------
#
# Both panes get new ids; only the role agent names survive the move.
STALE_DRIVER_PANE=$(jq -r '.topology_generations | last | .driver_pane' "$EVIDENCE")
STALE_NAV_PANE=$(jq -r '.topology_generations | last | .navigator_pane' "$EVIDENCE")
herdr_cli pane move "$STALE_DRIVER_PANE" --new-workspace --label moved --tab-label moved --no-focus >/dev/null
herdr_cli pane move "$STALE_NAV_PANE" --tab "$(role_field pair-driver tab_id)" --split right \
  --target-pane "$(role_field pair-driver pane_id)" --no-focus >/dev/null

FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null || fail "moved pair not recovered from role identity"
[ "$(generations)" -eq 2 ] || fail "recovery did not record a new topology generation"
jq -e --arg dp "$(role_field pair-driver pane_id)" --arg np "$(role_field pair-navigator pane_id)" \
  '(.topology_generations | last)
   | .generation == 2 and .driver_pane == $dp and .navigator_pane == $np' "$EVIDENCE" >/dev/null \
  || fail "recovered generation does not record the moved panes"
jq -e --arg dp "$STALE_DRIVER_PANE" --arg np "$STALE_NAV_PANE" \
  '.roles.driver.pane != $dp and .roles.navigator.pane != $np' "$EVIDENCE" >/dev/null \
  || fail "recovery kept the stale role panes"

FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null || fail "unchanged topology refused recovery"
[ "$(generations)" -eq 2 ] || fail "unchanged topology recorded a duplicate generation"

# --- recovery refuses every unsafe role identity ----------------------------
BEFORE=$(cat "$EVIDENCE")
NAV_PANE=$(role_field pair-navigator pane_id)

FM_FAKE_COPY_DRIFT=1 FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null 2>&1 \
  && fail "recovery accepted a role bound to another copy"
[ "$BEFORE" = "$(cat "$EVIDENCE")" ] || fail "copy-mismatched recovery mutated the recorded topology"

herdr_cli agent rename "$NAV_PANE" --clear >/dev/null
FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null 2>&1 \
  && fail "recovery accepted a missing role identity"
[ "$BEFORE" = "$(cat "$EVIDENCE")" ] || fail "missing-identity recovery mutated the recorded topology"
herdr_cli agent rename "$NAV_PANE" pair-navigator >/dev/null

herdr_cli agent rename decoy pair-navigator >/dev/null
FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null 2>&1 \
  && fail "recovery accepted a duplicated role identity"
[ "$BEFORE" = "$(cat "$EVIDENCE")" ] || fail "duplicated-identity recovery mutated the recorded topology"
herdr_cli agent rename decoy --clear >/dev/null

herdr_cli pane move "$NAV_PANE" --new-workspace --label split --tab-label split --no-focus >/dev/null
FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null 2>&1 \
  && fail "recovery accepted a broken pair topology"
[ "$BEFORE" = "$(cat "$EVIDENCE")" ] || fail "broken-topology recovery mutated the recorded topology"

# A restored endpoint recovers normally and appends the next generation.
herdr_cli pane move "$(role_field pair-navigator pane_id)" --tab "$(role_field pair-driver tab_id)" \
  --split right --target-pane "$(role_field pair-driver pane_id)" --no-focus >/dev/null
FM_PAIR_HERDR="$FAKEBIN/herdr" "$HELPER" recover "$EVIDENCE" >/dev/null || fail "restored pair not recovered"
[ "$(generations)" -eq 3 ] || fail "restored pair did not append a topology generation"

# --- composition refusals ----------------------------------------------------
#
# A stale recorded pane id must NOT be treated as a failure: the roles are live,
# correctly labelled, and adjacent, so composition resolves them by identity.
reset_pair
FM_FAKE_STALE_PANE=1 run_pair >/dev/null || fail "stale recorded pane id refused a live pair"
jq -e '.state == "ready"' "$EVIDENCE" >/dev/null || fail "stale recorded pane id blocked ready evidence"
assert_present "$HOME_DIR/data/pair/ready" "stale recorded pane id withheld the barrier"

for scenario in missing wrongsession wrongtab nonadjacent dupname lostname copydrift noack; do
  reset_pair
  case "$scenario" in
    missing) export FM_FAKE_MISSING_NAV=1 ;;
    wrongsession) export FM_FAKE_WRONG_SESSION=1 ;;
    wrongtab) export FM_FAKE_WRONG_TAB=1 ;;
    nonadjacent) export FM_FAKE_NONADJACENT=1 ;;
    dupname) export FM_FAKE_DUP_NAME=1 ;;
    lostname) export FM_FAKE_LOST_NAME=1 ;;
    copydrift) export FM_FAKE_COPY_DRIFT=1 ;;
    noack) export FM_FAKE_NO_NAV_ACK=1 ;;
  esac
  if run_pair >/dev/null 2>&1; then fail "$scenario failure reported ready"; fi
  [ ! -e "$HOME_DIR/data/pair/ready" ] || fail "$scenario released barrier"
  jq -e '.state == "failed" and (.failed_invariant | length > 0)' "$EVIDENCE" >/dev/null || fail "$scenario recovery evidence missing"
  jq -e '.topology_generations == []' "$EVIDENCE" >/dev/null || fail "$scenario recorded a topology generation"
  unset FM_FAKE_MISSING_NAV FM_FAKE_WRONG_SESSION FM_FAKE_WRONG_TAB FM_FAKE_NONADJACENT \
    FM_FAKE_DUP_NAME FM_FAKE_LOST_NAME FM_FAKE_COPY_DRIFT FM_FAKE_NO_NAV_ACK
 done

# Ordinary dispatch remains its own path and receives no pair facts.
reset_pair
FM_HOME="$HOME_DIR" FM_FIXTURE="$TMP_ROOT" "$FAKEBIN/spawn" ordinary "$PROJECT" >/dev/null
assert_present "$HOME_DIR/state/ordinary.meta" "ordinary dispatch metadata missing"
[ ! -e "$HOME_DIR/data/ordinary/recovery.json" ] || fail "ordinary dispatch received pair evidence"
[ ! -e "$HOME_DIR/data/ordinary/pair-log.md" ] || fail "ordinary dispatch received pair history"

pass "paired-review composition, identity recovery, barrier, instructions, failures, and ordinary dispatch"
