#!/usr/bin/env bash
# Behavior tests for the opt-in home lease (config/home-lease): renewal from session start, a worker
# claim before launch, delivery that stops when the lease moves, and a step loop that writes only while
# its host holds the lease. Every case runs the real commands against the stand-in for Dev 5001 in
# tests/fm-task-fake-api, with the two lease tables added. With config/home-lease absent every path is
# unchanged; the older suites (fm-host, fm-task, fm-task-shadow) hold that claim.
# shellcheck disable=SC2016 # fixture children expand their own variables
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v node >/dev/null 2>&1 || { printf 'skip - node is not installed\n'; exit 0; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'

TMP_ROOT=$(fm_test_tmproot fm-home-lease-hardening)
TOKEN="tok-$$-$RANDOM"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
chmod 600 "$TMP_ROOT/token"

node - "$ROOT/tests/fm-task-fake-api/schema.json" "$TMP_ROOT/schema.json" <<'JS'
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[2]));
s.fm_host = {ops:['list','get','create','patch'],u:[['hostId']],f:{hostId:{t:'s',m:128},sshAlias:{t:'s',n:1,m:128},fmVersion:{t:'s',n:1,m:64},toolsJson:{t:'s',n:1},lastHeartbeatAt:{t:'d',n:1},registeredAt:{t:'d',n:1},wakeQueueLength:{t:'i',n:1},liveWorkers:{t:'i',n:1}}};
s.fm_home_lease = {ops:['list','get','create','patch'],u:[['home','generation']],f:{home:{t:'s',m:64},generation:{t:'i'},hostId:{t:'s',m:128},takenAt:{t:'d'},heartbeatAt:{t:'d'},releasedAt:{t:'d',n:1}}};
fs.writeFileSync(process.argv[3], JSON.stringify(s));
JS
node "$ROOT/tests/fm-task-fake-api/server.mjs" "$TMP_ROOT/port" "$TMP_ROOT/schema.json" "$TOKEN" &
API_PID=$!
HOMES=()
cleanup() {
  local h
  kill "$API_PID" 2>/dev/null || true
  for h in "${HOMES[@]:-}"; do [ -z "$h" ] || FM_HOME="$h" "$ROOT/bin/fm-task-step-loop.sh" stop >/dev/null 2>&1 || true; done
  fm_test_cleanup
}
trap cleanup EXIT
for ((i = 0; i < 100; i++)); do [ ! -s "$TMP_ROOT/port" ] || break; sleep 0.05; done
BASE="http://127.0.0.1:$(< "$TMP_ROOT/port")"
export FM_TASK_BASE_URL="$BASE" FM_TASK_TOKEN_FILE="$TMP_ROOT/token"

LEASE_HOME=fm-probe-lease
db() { curl -s "$BASE/__x/rows/$1"; }
api() { curl -s -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' "$@"; }
lease_row() { db fm_home_lease | jq -c --arg h "$LEASE_HOME" '[.[] | select(.home == $h)] | sort_by(.generation) | last'; }
reset_db() { curl -s -X POST "$BASE/__x/reset" >/dev/null; }

# A probe home with the lease on and its own host id. Echoes the home path.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$LEASE_HOME" > "$home/config/home-lease"
  HOMES+=("$home")
  printf '%s\n' "$home"
}

# A session stand-in: a process whose name the session lock accepts as a harness, kept alive for <seconds>.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
session() {  # <home> <host-id> <seconds> <log>: run fm-lock.sh in a live session process, in the background
  local home=$1 host=$2 seconds=$3 log=$4
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$home" FM_HOST_ID="$host" FM_HOST_HEARTBEAT_EVERY=1 FM_TASK_STEP_EVERY=1 \
    "$FAKEBIN/claude" -c "'$ROOT/bin/fm-lock.sh' > '$log' 2>&1; sleep $seconds" > /dev/null 2>&1 &
  SESSION_PID=$!
}
stop_loop() { FM_HOME="$1" "$ROOT/bin/fm-task-step-loop.sh" stop >/dev/null 2>&1 || true; }

# A first turn longer than 180 s must not lose the lease: the session renews it from session start, before any
# watcher is armed. The case reads the lease's heartbeat after the take and waits for it to move with nothing armed.
test_session_start_renews_the_lease_without_a_watcher() {
  reset_db
  local home first later i
  home=$(make_home renew)
  session "$home" probe-a 30 "$TMP_ROOT/renew.log"
  for ((i = 0; i < 100; i++)); do grep -q 'lock acquired' "$TMP_ROOT/renew.log" 2>/dev/null && break; sleep 0.1; done
  grep -q 'lock acquired' "$TMP_ROOT/renew.log" || { echo "session start did not finish: $(cat "$TMP_ROOT/renew.log")"; return 1; }
  first=$(lease_row | jq -r .heartbeatAt)
  [ "$(lease_row | jq -r .hostId)" = probe-a ] || { echo "the session did not take the lease: $(lease_row)"; return 1; }
  for ((i = 0; i < 100; i++)); do
    later=$(lease_row | jq -r .heartbeatAt)
    [ "$later" = "$first" ] || break
    sleep 0.1
  done
  stop_loop "$home"
  kill "$SESSION_PID" 2>/dev/null
  [ "$later" != "$first" ] || { echo "the lease heartbeat stayed at $first with no watcher armed"; return 1; }
  [ ! -e "$home/state/.arm" ] || { echo 'the case armed a watcher'; return 1; }
}

# A worker launched after the host's last zero-worker heartbeat must still block a takeover. The spawn claims its
# slot before any endpoint exists (the fake tmux refuses, so none ever does); every heartbeat that follows, with no
# worker record yet, keeps the claim counted; a second host then finds the lease expired and is still refused.
spawn_fixture() {  # <home> <task>: a project and a brief a ship spawn accepts, and a tmux that refuses
  local home=$1 id=$2 proj="$TMP_ROOT/projects/proj"
  if [ ! -d "$proj" ]; then
    mkdir -p "$proj"
    git -C "$proj" init -q && git -c user.name=test -c user.email=test@example.com -C "$proj" commit -q --allow-empty -m init || return 1
  fi
  mkdir -p "$TMP_ROOT/tmuxfail" "$home/data/$id"
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/tmuxfail/tmux"
  chmod +x "$TMP_ROOT/tmuxfail/tmux"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the claim.\n\n## Firstmate spec\nNone.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' > "$home/data/$id/brief.md"
}
run_spawn() {  # <home> <host-id> <task>
  local home=$1 host=$2 id=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_HOST_ID="$host" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$TMP_ROOT/tmuxfail:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$TMP_ROOT/projects/proj" claude --mode direct-PR --yolo off 2>&1
}
host_row() { db fm_host | jq -c --arg h "$1" '.[] | select(.hostId == $h)'; }
wait_for() {  # <seconds> <command...>: poll until the command succeeds
  local limit=$1 i; shift
  for ((i = 0; i < limit * 10; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}
lease_taken_by() { [ "$(lease_row | jq -r '.hostId // empty')" = "$1" ]; }
workers_are() { [ "$(host_row "$1" | jq -r .liveWorkers)" = "$2" ]; }

test_a_worker_claim_blocks_takeover_until_the_worker_record_counts() {
  reset_db
  local home out
  home=$(make_home claim)
  session "$home" probe-a 40 "$TMP_ROOT/claim.log"
  wait_for 10 lease_taken_by probe-a || { echo "the session did not take the lease: $(cat "$TMP_ROOT/claim.log")"; return 1; }
  wait_for 10 workers_are probe-a 0 || { echo "no zero-worker heartbeat: $(host_row probe-a)"; return 1; }
  # the claim a launch in progress holds (a failed launch gives it back: the next case)
  out=$(FM_HOME="$home" FM_HOST_ID=probe-a bash -c 'source "$1/bin/fm-wake-lib.sh"; source "$1/bin/fm-home-lease-lib.sh"; fm_home_lease_claim_worker claim-w1' _ "$ROOT" 2>&1) || { echo "the claim was refused: $out"; return 1; }
  [ -f "$home/state/.host-claim.claim-w1" ] || { echo "the claim left no record: $out"; return 1; }
  workers_are probe-a 1 || { echo "the spawn did not raise liveWorkers: $(host_row probe-a)"; return 1; }
  sleep 3   # at least two heartbeats, each counting no worker record
  workers_are probe-a 1 || { echo "a heartbeat erased the claim: $(host_row probe-a)"; return 1; }
  # the session ends; its lease lapses
  kill "$SESSION_PID" 2>/dev/null; stop_loop "$home"
  api -X PATCH "$BASE/api/fm_home_lease/$(lease_row | jq -r .id)" -d '{"heartbeatAt":"2026-01-01T00:00:00.000Z"}' >/dev/null
  FM_HOST_ID=probe-b FM_HOME="$TMP_ROOT/other" FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" register >/dev/null
  out=$(FM_HOST_ID=probe-b FM_HOME="$TMP_ROOT/other" FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" lease take)
  case "$out" in *'held by probe-a'*'liveWorkers=1'*) ;; *) echo "takeover was not refused with the holder and count: $out"; return 1 ;; esac
  lease_taken_by probe-a || { echo "the lease moved: $(lease_row)"; return 1; }
}

# A spawn that fails before any worker record exists gives its slot back at once: the claim file goes, the host count
# falls, and the lease can be handed over. The refusing tmux reads the host row on its way, which shows the claim
# was already counted before any endpoint was asked for.
test_a_failed_spawn_gives_its_worker_slot_back() {
  reset_db
  local home out
  home=$(make_home giveback)
  session "$home" probe-a 40 "$TMP_ROOT/giveback.log"
  wait_for 10 lease_taken_by probe-a || { echo "the session did not take the lease: $(cat "$TMP_ROOT/giveback.log")"; return 1; }
  wait_for 10 workers_are probe-a 0 || { echo "no zero-worker heartbeat: $(host_row probe-a)"; return 1; }
  spawn_fixture "$home" giveback-w1 || return 1
  mkdir -p "$TMP_ROOT/tmuxseen"
  printf '#!/bin/sh\ncurl -s -H "Authorization: Bearer %s" "%s/api/fm_host?\\$top=100" >> "%s/seen"\nexit 1\n' "$TOKEN" "$BASE" "$TMP_ROOT/tmuxseen" > "$TMP_ROOT/tmuxfail/tmux"
  out=$(run_spawn "$home" probe-a giveback-w1)
  [ ! -e "$home/state/giveback-w1.meta" ] || { echo "the spawn left a worker record: $out"; return 1; }
  grep -q '"liveWorkers":1' "$TMP_ROOT/tmuxseen/seen" 2>/dev/null || { echo "the claim was not counted before the endpoint step: $(cat "$TMP_ROOT/tmuxseen/seen" 2>&1) $out"; return 1; }
  [ ! -e "$home/state/.host-claim.giveback-w1" ] || { echo "the failed spawn left its claim file: $out"; return 1; }
  workers_are probe-a 0 || { echo "the failed spawn left liveWorkers raised: $(host_row probe-a) $out"; return 1; }
  # the session ends at once; nothing is left to lower the count later
  kill "$SESSION_PID" 2>/dev/null; stop_loop "$home"
  api -X PATCH "$BASE/api/fm_home_lease/$(lease_row | jq -r .id)" -d '{"heartbeatAt":"2026-01-01T00:00:00.000Z"}' >/dev/null
  FM_HOST_ID=probe-b FM_HOME="$TMP_ROOT/other" FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" register >/dev/null
  FM_HOST_ID=probe-b FM_HOME="$TMP_ROOT/other" FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" lease take >/dev/null || { echo 'the takeover was refused after the failed spawn gave its slot back'; return 1; }
  lease_taken_by probe-b || { echo "the lease did not move: $(lease_row)"; return 1; }
}

# The give-back rules, driven through the real spawn in a spawn world (fake tmux, real worktree and backlog). A tmux
# wrapper fails the one call a case names: FM_FAKE_FAIL_ON=new-window (before any endpoint exists) or Enter (the key that
# runs the launch command, refused once the command was typed into an endpoint that stays open).
world() {  # <name> <task>: a home that holds the lease as probe-a, ready to spawn <task>
  local name=$1 id=$2
  home=$(make_home "$name")
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$home/projects/proj" "$home/pane" "fixture-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$home/tools" claude)
  fm_test_fake_gh "$fakebin"
  mv "$fakebin/tmux" "$fakebin/tmux.real"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
here=$(dirname "$0")
case " $* " in *'#{pane_tty}'*) [ -z "${FM_FAKE_TTY:-}" ] || { printf '%s\n' "$FM_FAKE_TTY"; exit 0; } ;; esac
case "${FM_FAKE_FAIL_ON:-}" in
  new-window) [ "${1:-}" = new-window ] && exit 1 ;;
  Enter)
    if [ "${1:-}" = send-keys ]; then
      case " $* " in *" -l "*) : > "$here/.literal-sent" ;; esac
      case " $* " in *" Enter "*) [ ! -e "$here/.literal-sent" ] || exit 1 ;; esac
    fi ;;
esac
exec "$here/tmux.real" "$@"
SH
  chmod +x "$fakebin/tmux"
  tasks-axi add "$id" "Build $name" --kind ship --file "$home/data/backlog.md" >/dev/null
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" register >/dev/null
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" lease take >/dev/null || return 1
}
wspawn() {  # <task> [spawn args...]: a ship spawn (or relaunch) as probe-a; CODE_ROOT picks the tool copy
  local id=$1; shift
  FM_HOST_ID=probe-a ROOT=${CODE_ROOT:-$ROOT} fm_test_run_spawn "$home" "${PANE_AT:-$home/pane}" "$fakebin" "$id" "$@"
}
pane_with_a_shell() {  # writes the pty path of a pane whose foreground is a bare bash to pane.tty; the holder ends after 300 s
  local i
  rm -f "$TMP_ROOT/pane.tty"
  python3 - > "$TMP_ROOT/pane.tty" 2>/dev/null <<'PY' &
import os, pty, fcntl, termios, subprocess, sys, time
master, slave = pty.openpty()
def child():
    os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)
subprocess.Popen(['bash', '-c', 'read x'], stdin=slave, stdout=slave, stderr=slave, preexec_fn=child, close_fds=True)
print(os.ttyname(slave)); sys.stdout.flush()
time.sleep(300)
PY
  PANE_HOLDER=$!
  for ((i = 0; i < 50; i++)); do [ -s "$TMP_ROOT/pane.tty" ] && break; sleep 0.1; done
  [ -s "$TMP_ROOT/pane.tty" ]
}
claimed() { [ -e "$home/state/.host-claim.$1" ]; }

# Launch delivered, then the spawn fails (the Enter key is refused) with the endpoint still open: a worker may be
# running, so the claim and the raised count stay.
test_a_failure_after_the_launch_keeps_the_claim() {
  reset_db
  local out
  world afterlaunch al-w1 || { echo 'no world'; return 1; }
  out=$(FM_FAKE_FAIL_ON=Enter wspawn al-w1 "$home/projects/proj" --mode direct-PR --yolo off) && { echo "the spawn did not fail: $out"; return 1; }
  claimed al-w1 || { echo "the claim was removed although the launch was sent: $out"; return 1; }
  workers_are probe-a 1 || { echo "the count was lowered although the launch was sent: $(host_row probe-a) $out"; return 1; }
}

# A relaunch fails before its replacement starts (its pane has drifted out of the recorded worktree), and its task
# record stays: the replacement's claim still goes back.
test_a_failed_relaunch_gives_its_claim_back() {
  reset_db
  local out
  world relaunch rl-w1 || { echo 'no world'; return 1; }
  out=$(wspawn rl-w1 "$home/projects/proj" --mode direct-PR --yolo off) || { echo "the first spawn failed: $out"; return 1; }
  # a heartbeat has since counted the live record and dropped the claim
  rm -f "$home/state/.host-claim.rl-w1"
  api -X PATCH "$BASE/api/fm_host/$(host_row probe-a | jq -r .id)" -d '{"liveWorkers":1}' | jq -e '.success == true' >/dev/null || { echo 'could not seed the count'; return 1; }
  # the old endpoint is a pane whose foreground is a bare shell: positively agent-free, so a relaunch may replace it
  local tty
  pane_with_a_shell || { echo 'could not make a pane tty'; return 1; }
  tty=$(cat "$TMP_ROOT/pane.tty")
  out=$(FM_FAKE_TTY=$tty PANE_AT="$home/elsewhere" wspawn rl-w1 --relaunch) && { echo "the relaunch did not fail: $out"; return 1; }
  case "$out" in *'not its recorded worktree'*) ;; *) echo "the relaunch did not stop at the worktree check: $out"; return 1 ;; esac
  [ -e "$home/state/rl-w1.meta" ] || { echo "the relaunch removed the task record: $out"; return 1; }
  ! claimed rl-w1 || { echo "the failed relaunch left its claim file: $out"; return 1; }
  kill "${PANE_HOLDER:-0}" 2>/dev/null
  workers_are probe-a 1 || { echo "the failed relaunch left liveWorkers at $(host_row probe-a | jq -r .liveWorkers), want 1: $out"; return 1; }
}

# The give-back runs while the spawn locks are still held: a retry of the same task started during it is refused.
test_the_give_back_runs_under_the_task_spawn_lock() {
  reset_db
  local code="$TMP_ROOT/code" out first
  git clone -q "$ROOT" "$code" || { echo 'could not copy the tools'; return 1; }
  cp -a "$ROOT/bin/." "$code/bin/" || { echo 'could not copy the tools'; return 1; }
  cat > "$code/bin/fm-host.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "worker release" ]; then : > "$FM_TEST_RELEASE_MARK"; sleep 4; fi
exec node "$(dirname "${BASH_SOURCE[0]}")/fm-host-lib.mjs" "$@"
SH
  chmod +x "$code/bin/fm-host.sh"
  world lockorder lo-w1 || { echo 'no world'; return 1; }
  export FM_TEST_RELEASE_MARK="$TMP_ROOT/release-mark"; rm -f "$FM_TEST_RELEASE_MARK"
  (CODE_ROOT=$code FM_FAKE_FAIL_ON=new-window wspawn lo-w1 "$home/projects/proj" --mode direct-PR --yolo off > "$TMP_ROOT/lo-first.out" 2>&1) &
  first=$!
  wait_for 60 test -e "$FM_TEST_RELEASE_MARK" || { echo "the first spawn never gave its slot back: $(cat "$TMP_ROOT/lo-first.out")"; kill "$first"; return 1; }
  out=$(CODE_ROOT=$code FM_FAKE_FAIL_ON=new-window wspawn lo-w1 "$home/projects/proj" --mode direct-PR --yolo off)
  wait "$first"
  unset FM_TEST_RELEASE_MARK
  # the spawn locks nest (task set, then task); whichever the retry meets first refuses it while the give-back runs
  case "$out" in *'another spawn is already creating task lo-w1'*|*'task set is locked by another spawn'*) ;; *) echo "a retry during the give-back was not refused: $out"; return 1 ;; esac
  workers_are probe-a 0 || { echo "the count is $(host_row probe-a | jq -r .liveWorkers), want 0"; return 1; }
}

# A launch that never produced a worker record must not block hand-over for ever.
test_an_expired_claim_stops_counting() {
  reset_db
  local home
  home=$(make_home expire)
  session "$home" probe-a 40 "$TMP_ROOT/expire.log"
  wait_for 10 lease_taken_by probe-a || { echo "the session did not take the lease: $(cat "$TMP_ROOT/expire.log")"; return 1; }
  printf '%s\n' "$(( $(date +%s) - 700 ))" > "$home/state/.host-claim.gone-w1"
  api -X PATCH "$BASE/api/fm_host/$(host_row probe-a | jq -r .id)" -d '{"liveWorkers":1}' | jq -e '.success == true' >/dev/null || { echo 'could not seed the count'; return 1; }
  wait_for 10 test ! -e "$home/state/.host-claim.gone-w1" || { echo 'the expired claim file stayed'; return 1; }
  wait_for 10 workers_are probe-a 0 || { echo "an expired claim still counts: $(host_row probe-a)"; return 1; }
  stop_loop "$home"; kill "$SESSION_PID" 2>/dev/null
}

# The lease moves while a delivery run is under way: events the run had not claimed yet stay unclaimed. The wake
# queue lock is held from outside, so the run stops after claiming event 1 until the case has moved the lease.
add_event() {  # <task> <seq>
  api -X POST "$BASE/api/fm_task_event" -d "{\"taskId\":\"$1\",\"seq\":$2,\"kind\":\"comment\",\"actor\":\"probe\",\"actorRole\":\"system\",\"body\":\"{}\",\"idempotencyKey\":\"probe-$1-$2\"}" | jq -e '.success == true' >/dev/null
}
deliveries() { db fm_task_delivery | jq -c '[.[] | .seq] | sort'; }
delivery_count_is() { [ "$(db fm_task_delivery | jq length)" -ge "$1" ]; }

test_delivery_stops_claiming_when_the_lease_moves() {
  reset_db
  local home task=fm-probe-lease-deliver rc holder
  home=$(make_home deliver)
  export_a() { FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$@"; }
  export_a "$ROOT/bin/fm-host.sh" register >/dev/null || { echo 'probe-a could not register'; return 1; }
  export_a "$ROOT/bin/fm-host.sh" lease take >/dev/null || { echo 'probe-a could not take the lease'; return 1; }
  export_a "$ROOT/bin/fm-task.sh" deliver "$task" --consumer probe-consumer >/dev/null || { echo 'activation failed'; return 1; }
  for i in 1 2 3; do add_event "$task" "$i" || { echo 'could not add the probe events'; return 1; }; done
  export FM_LOCK_STALE_AFTER=600   # a held lock stays held for the whole case
  FM_HOME="$home" bash -c 'source "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; : > "$2/held"; sleep 120' _ "$ROOT" "$home/state" &
  holder=$!
  wait_for 10 test -e "$home/state/held" || { echo 'the lock holder did not start'; kill "$holder"; return 1; }
  export_a "$ROOT/bin/fm-task.sh" deliver "$task" --consumer probe-consumer > "$TMP_ROOT/deliver.log" 2>&1 &
  local run=$!
  wait_for 15 delivery_count_is 1 || { echo "the run claimed no event: $(cat "$TMP_ROOT/deliver.log")"; kill "$holder" "$run"; return 1; }
  # the lease moves to probe-b while event 1's wake append waits
  FM_HOME="$TMP_ROOT/other" FM_HOST_ID=probe-b FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" register >/dev/null
  api -X PATCH "$BASE/api/fm_home_lease/$(lease_row | jq -r .id)" -d '{"releasedAt":"2026-11-14T00:00:00.000Z"}' >/dev/null
  api -X POST "$BASE/api/fm_home_lease" -d "{\"home\":\"$LEASE_HOME\",\"generation\":2,\"hostId\":\"probe-b\",\"takenAt\":\"$(date -u +%FT%T.000Z)\",\"heartbeatAt\":\"$(date -u +%FT%T.000Z)\"}" | jq -e '.success == true' >/dev/null || { echo 'the lease did not move'; return 1; }
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -rf "$home/state/.wake-queue.lock"
  wait "$run"; rc=$?
  unset FM_LOCK_STALE_AFTER
  [ "$rc" -eq 5 ] || { echo "the run exited $rc, want 5: $(cat "$TMP_ROOT/deliver.log")"; return 1; }
  [ "$(deliveries)" = '[1]' ] || { echo "the former holder claimed events after the move: $(deliveries)"; return 1; }
}

# A host that does not hold the lease writes no step: the loop checks ownership before every pass, skips the pass,
# logs the loss once, and writes again when ownership returns. The writer is a stub that records each call.
writer_calls() { grep -c . "$TMP_ROOT/writer.log" 2>/dev/null || true; }
writes_seen() { [ "$(writer_calls)" -ge "$1" ]; }

test_step_loop_writes_only_while_its_host_holds_the_lease() {
  reset_db
  local home calls
  home=$(make_home steploop)
  : > "$TMP_ROOT/writer.log"
  printf '#!/bin/sh\necho "$@" >> "%s"\n' "$TMP_ROOT/writer.log" > "$TMP_ROOT/writer.sh"
  chmod +x "$TMP_ROOT/writer.sh"
  : > "$home/config/task-shadow"
  # a tmux with no window: the task's endpoint reads dead, so every pass has a step to write
  mkdir -p "$TMP_ROOT/tmuxquiet" && printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/tmuxquiet/tmux" && chmod +x "$TMP_ROOT/tmuxquiet/tmux"
  printf 'window=test:fm-t1\nkind=ship\nharness=claude\nbackend=tmux\nspawn_gen=g1\n' > "$home/state/t1.meta"
  local -a hostb=("FM_HOME=$TMP_ROOT/other" FM_HOST_ID=probe-b "FM_HOME_NAME=$LEASE_HOME")
  env "${hostb[@]}" "$ROOT/bin/fm-host.sh" register >/dev/null || { echo 'probe-b could not register'; return 1; }
  env "${hostb[@]}" "$ROOT/bin/fm-host.sh" lease take >/dev/null || { echo 'probe-b could not take the lease'; return 1; }
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" register >/dev/null
  sleep 60 & local live=$!
  printf '%s\n' "$live" > "$home/state/.lock"
  FM_HOME="$home" FM_HOST_ID=probe-a FM_TASK_SHADOW_WRITER="$TMP_ROOT/writer.sh" FM_TASK_STEP_EVERY=1 FM_HOST_HEARTBEAT_EVERY=1 PATH="$TMP_ROOT/tmuxquiet:$PATH" \
    "$ROOT/bin/fm-task-step-loop.sh" start >/dev/null
  sleep 4
  calls=$(writer_calls)
  [ "$calls" = 0 ] || { echo "the loop wrote $calls step(s) without the lease: $(cat "$TMP_ROOT/writer.log")"; kill "$live"; return 1; }
  grep -q 'lost the home lease' "$home/state/.task-step-loop.log" || { echo "the loop did not log the lost lease: $(cat "$home/state/.task-step-loop.log" 2>&1)"; kill "$live"; return 1; }
  # ownership returns: probe-b releases, probe-a takes generation 3
  env "${hostb[@]}" FM_HOST_LIVE_WORKERS=0 FM_HOST_WAKE_QUEUE_LENGTH=0 "$ROOT/bin/fm-host.sh" heartbeat >/dev/null
  env "${hostb[@]}" FM_HOST_LIVE_WORKERS=0 "$ROOT/bin/fm-host.sh" lease release >/dev/null
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" lease take >/dev/null || { echo 'probe-a could not take the lease back'; kill "$live"; return 1; }
  wait_for 10 writes_seen 1 || { echo 'the loop wrote nothing after ownership returned'; kill "$live"; return 1; }
  grep -q 'holds the home lease' "$home/state/.task-step-loop.log" || { echo "no regain line: $(cat "$home/state/.task-step-loop.log")"; kill "$live"; return 1; }
  stop_loop "$home"; kill "$live" 2>/dev/null
}

# One pass runs a crew-state read (10 s) and a replay (60 s) per task. With slow replays the lease must still be renewed
# between tasks: the stub writer sleeps on every call but `step`, three tasks hold an unsent status line each, and the
# host's heartbeat must move at least every few seconds while the pass is under way, not once per pass.
test_a_slow_replay_still_lets_the_heartbeat_run() {
  reset_db
  local home t i prev cur stamp max=0 changes=0 gap
  home=$(make_home slowreplay)
  printf '#!/bin/sh\n[ "$1" = step ] || sleep 3\necho "$@" >> "%s"\n' "$TMP_ROOT/slow-writer.log" > "$TMP_ROOT/slow-writer.sh"
  chmod +x "$TMP_ROOT/slow-writer.sh"
  : > "$home/config/task-shadow"
  mkdir -p "$TMP_ROOT/tmuxquiet" && printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/tmuxquiet/tmux" && chmod +x "$TMP_ROOT/tmuxquiet/tmux"
  for t in t1 t2 t3; do
    printf 'window=test:fm-%s\nkind=ship\nharness=claude\nbackend=tmux\nspawn_gen=g1\n' "$t" > "$home/state/$t.meta"
    printf 'working: one line the record has not stored\n' > "$home/state/$t.status"
    printf '0\n' > "$home/state/$t.status-sent"
  done
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" register >/dev/null
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" "$ROOT/bin/fm-host.sh" lease take >/dev/null || { echo 'probe-a could not take the lease'; return 1; }
  sleep 60 & local live=$!
  printf '%s\n' "$live" > "$home/state/.lock"
  FM_HOME="$home" FM_HOST_ID=probe-a FM_HOME_NAME="$LEASE_HOME" FM_TASK_SHADOW_WRITER="$TMP_ROOT/slow-writer.sh" FM_TASK_STEP_EVERY=1 FM_HOST_HEARTBEAT_EVERY=1 \
    FM_TASK_REPLAY_EVERY=600 PATH="$TMP_ROOT/tmuxquiet:$PATH" "$ROOT/bin/fm-task-step-loop.sh" start >/dev/null
  # watch the host's heartbeat for 14 s; the first pass alone takes about 9 s of replays
  prev=$(host_row probe-a | jq -r .lastHeartbeatAt)
  stamp=$(date +%s.%N)
  for ((i = 0; i < 56; i++)); do
    sleep 0.25
    cur=$(host_row probe-a | jq -r .lastHeartbeatAt)
    if [ "$cur" != "$prev" ]; then
      gap=$(awk -v a="$(date +%s.%N)" -v b="$stamp" 'BEGIN { printf "%.2f", a - b }')
      awk -v g="$gap" -v m="$max" 'BEGIN { exit !(g > m) }' && max=$gap
      stamp=$(date +%s.%N); prev=$cur; changes=$((changes + 1))
    fi
  done
  stop_loop "$home"; kill "$live" 2>/dev/null
  [ "$(grep -c . "$TMP_ROOT/slow-writer.log" 2>/dev/null || true)" -ge 3 ] || { echo "the replays did not run: $(cat "$TMP_ROOT/slow-writer.log" 2>&1)"; return 1; }
  [ "$changes" -ge 4 ] || { echo "the heartbeat moved only $changes time(s) in 14 s"; return 1; }
  awk -v m="$max" 'BEGIN { exit !(m < 5) }' || { echo "the heartbeat went $max s without moving while replays ran"; return 1; }
}

run_case() {
  local name=$1
  if "$name"; then pass "$name"; else fail "$name"; fi
}

run_case test_session_start_renews_the_lease_without_a_watcher
run_case test_a_worker_claim_blocks_takeover_until_the_worker_record_counts
run_case test_a_failed_spawn_gives_its_worker_slot_back
run_case test_a_failure_after_the_launch_keeps_the_claim
run_case test_a_failed_relaunch_gives_its_claim_back
run_case test_the_give_back_runs_under_the_task_spawn_lock
run_case test_an_expired_claim_stops_counting
run_case test_delivery_stops_claiming_when_the_lease_moves
run_case test_step_loop_writes_only_while_its_host_holds_the_lease
run_case test_a_slow_replay_still_lets_the_heartbeat_run
