#!/usr/bin/env bash
# FW1-FW4 (firstmate#192): a worker waiting on firstmate holds the drain's ack.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-firstmate-wait)
NOW=$(date +%s)
new_case() {  # <name> <task> <verb> <age-minutes>
  dir="$TMP_ROOT/$1"
  state="$dir/state"
  mkdir -p "$state" "$dir/config"
  printf 'window=t:%s\nkind=ship\n' "$2" > "$state/$2.meta"
  printf '%s [at=%s]: a worker waits on firstmate\n' "$3" "$((NOW - $4 * 60))" > "$state/$2.status"
  printf '%s\n' "$2" > "$dir/task"
}
queue_row() {  # <state> ; one durable row belonging to this actor
  printf '%s\t1\tcheck\tprobe-key\tcheck: probe\n' "$NOW" >> "$1/.wake-queue"
}
drain() {  # <dir> [ack args...]
  local d=$1
  shift
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" "$ROOT/bin/fm-wake-drain.sh" "$@" 2>"$d/err"
}
ack_of() {  # <dir> <drain-err-file>: prints the ack arguments the drain named
  sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$1" | tail -1
}

# FW1: a done line 12 minutes old is listed and its ack is refused.
new_case fw1 done-task done 12
queue_row "$state"
drain "$dir" > "$dir/out" 2> "$dir/err"
grep -F 'FIRSTMATE OWES:' "$dir/out" >/dev/null || fail "FW1 no FIRSTMATE OWES block: $(cat "$dir/out")"
grep -E 'done-task done 12m' "$dir/out" >/dev/null || fail "FW1 listing lacks task, verb and age: $(cat "$dir/out")"
set -- $(ack_of "$dir/err")
[ "$#" = 2 ] || fail "FW1 no ack boundary: $(cat "$dir/err")"
if drain "$dir" --ack-through "$1" --recovery-generation "$2" > "$dir/out2"; then fail 'FW1 acknowledgement was accepted'; fi
grep -F 'acknowledgement refused while firstmate owes' "$dir/err" >/dev/null || fail "FW1 refusal wording: $(cat "$dir/err")"
[ -s "$state/.wake-queue" ] || fail 'FW1 acknowledged the queue anyway'
pass 'FW1 a firstmate-owed done wait is listed and its ack refused'

# FW2: a steering message answers the wait, so the ack is accepted.
mkdir -p "$state/done-task.inbox"
printf 'schema=fm-task-inbox.v1\nat=x\n--\nanswer\n' > "$state/done-task.inbox/001.msg"
touch "$state/done-task.firstmate-ack"
drain "$dir" > "$dir/out3"
grep -F 'FIRSTMATE OWES:' "$dir/out3" >/dev/null && fail 'FW2 still owed after firstmate acted'
set -- $(ack_of "$dir/err")
drain "$dir" --ack-through "$1" --recovery-generation "$2" > "$dir/out4" \
  || fail "FW2 ack refused after the steer: $(cat "$dir/err")"
pass 'FW2 a steer clears the wait and the ack is accepted'

# FW3: a paused line on an external wait is not firstmate's to answer.
new_case fw3 paused-task paused 30
queue_row "$state"
printf '11\n' > "$dir/config/firstmate-wait-minutes"
drain "$dir" > "$dir/out"
grep -F 'FIRSTMATE OWES:' "$dir/out" >/dev/null && fail 'FW3 a paused wait was listed as owed'
set -- $(ack_of "$dir/err")
drain "$dir" --ack-through "$1" --recovery-generation "$2" > "$dir/out2" \
  || fail "FW3 ack refused for an external wait: $(cat "$dir/err")"
pass 'FW3 a paused external wait leaves the ack alone'

# FW4: with the refusal removed, FW1 goes red.
MBIN="$TMP_ROOT/mbin"
mkdir -p "$MBIN"
cp -a "$ROOT/bin/." "$MBIN/"
perl -0pi -e 's/if \[ -n "\$\{ACK_THROUGH:-\}" \]; then/if false; then/' "$MBIN/fm-wake-drain.sh"
grep -q 'ACK_THROUGH:-' "$MBIN/fm-wake-drain.sh" && fail 'FW4 mutation left the refusal guard in place'
new_case fw4 done-task done 12
queue_row "$state"
mbin_drain() {  # <dir> [ack args...]
  local d=$1
  shift
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_CONFIG_OVERRIDE="$d/config" "$MBIN/fm-wake-drain.sh" "$@" 2>"$d/err"
}
mbin_drain "$dir" > "$dir/out"
set -- $(ack_of "$dir/err")
if ! mbin_drain "$dir" --ack-through "$1" --recovery-generation "$2" > "$dir/out2"; then
  fail 'FW4 the mutated drain still refused, so the scenario does not guard the refusal'
fi
[ ! -s "$state/.wake-queue" ] || fail 'FW4 the mutated drain did not consume the queue'
pass 'FW4 removing the refusal makes FW1 go red'
