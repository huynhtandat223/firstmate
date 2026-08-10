#!/usr/bin/env bash
# Compose two ordinary Firstmate task launches into one verified Herdr pair.
#
# Usage: fm-pair-compose.sh --pair-id ID --project DIR --mode MODE --yolo on|off
#   --task-file FILE --scope-file FILE
#   --driver-harness NAME [--driver-model NAME] [--driver-effort LEVEL]
#   --navigator-harness NAME [--navigator-model NAME] [--navigator-effort LEVEL]
#   [--context SOURCE]... [--check TEXT]...
#   fm-pair-compose.sh send <recovery.json> <driver|navigator> <message>
#   fm-pair-compose.sh recover <recovery.json>
#   fm-pair-compose.sh gate <recovery.json> <gate> <driver-head>
#   fm-pair-compose.sh finding <recovery.json> open|close <N-id>
#
# `send` is the single live-signal delivery API for both pair roles: it resolves
# the recipient task from the recovery evidence and submits through fm-send.sh,
# so a signal counts as delivered only when submission is verified. Herdr
# arranges pair topology only and is never used for text delivery.
#
# Herdr assigns a pane a new id every time it moves. It still accepts the old id
# as a LOOKUP KEY, but every response reports the pane's CURRENT id, so a
# recorded pane id is a hint that must never be compared against a live answer.
# A role's stable identity is its registered agent
# name (<pair-id>-driver, <pair-id>-navigator) bound to that role's isolated
# copy, and both composition and `recover` resolve the current pane, workspace,
# and tab from Herdr's own agent inventory under that identity. `recover`
# re-verifies a live pair after a move and records the resulting topology
# generation. Either path refuses, and records no generation, when a role
# identity is missing, duplicated, or bound to a copy that is not that role's.
#
# The task and scope files are owner-supplied authority. Context values are
# pointers, not copied requirements. The helper creates <ID> and <ID>-nav through
# fm-spawn.sh, waits for both role barrier acknowledgements, composes their Herdr
# panes, verifies role identity and reciprocal adjacency, writes recovery.json,
# and releases both role barriers through the verified send path. It never
# changes generic fm-spawn behavior.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FM_HOME=${FM_HOME:-$ROOT}
SPAWN=${FM_PAIR_SPAWN:-$ROOT/bin/fm-spawn.sh}
BRIEF=${FM_PAIR_BRIEF:-$ROOT/bin/fm-brief.sh}
SEND=${FM_PAIR_SEND:-$ROOT/bin/fm-send.sh}
HERDR=${FM_PAIR_HERDR:-herdr}
ACK_TIMEOUT=${FM_PAIR_ACK_TIMEOUT:-30}

usage() { sed -n '2,/^[^#]/p' "$0" | sed -n 's/^# \{0,1\}//p'; }
die() { echo "error: $*" >&2; exit 1; }
atom() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# Verified submission of one live pair signal through fm-send. A non-zero result
# means the signal was NOT submitted (failed or unconfirmed), so callers fail
# loudly and never retry, inject via Herdr, or fall back to a different message.
pair_send() {
  local evidence=$1 role=$2 message=$3
  local owner_home task_id
  owner_home=$(jq -r '.owner_home // empty' "$evidence" 2>/dev/null) || return 1
  task_id=$(jq -r --arg role "$role" '.roles[$role].task_id // empty' "$evidence" 2>/dev/null) || return 1
  [ -n "$owner_home" ] && [ -n "$task_id" ] || return 1
  FM_HOME="$owner_home" "$SEND" "$task_id" "$message" || return 1
}

# Resolve one live role endpoint from Herdr's own agent inventory and print
# "<pane>\t<workspace>\t<tab>" for it. With an agent name, exactly one live
# agent must carry that name and it must sit in this role's isolated copy; with
# an empty name - before composition has published the role names - exactly one
# live agent must sit in that copy. Every other outcome (missing, duplicated, or
# bound to another copy) returns non-zero so the caller refuses rather than
# acting on a guess. A copy matches when the agent's shell or foreground working
# directory is that copy or a directory inside it.
pair_resolve_role() {  # <session> <agent-name|''> <copy>
  local session=$1 name=$2 copy=$3 agents
  [ -n "$session" ] && [ -n "$copy" ] || return 1
  agents=$("$HERDR" --session "$session" agent list 2>/dev/null) || return 1
  printf '%s' "$agents" | jq -er --arg name "$name" --arg copy "$copy" '
    def in_copy($p): ($p != null) and (($p == $copy) or ($p | startswith($copy + "/")));
    def role_copy: in_copy(.foreground_cwd) or in_copy(.cwd);
    [ .result.agents[]? ] as $all
    | (if $name == "" then [ $all[] | select(role_copy) ]
       else [ $all[] | select(.name == $name) ] end)
    | select(length == 1)[0]
    | select(role_copy)
    | select(((.pane_id // "") != "") and ((.workspace_id // "") != "") and ((.tab_id // "") != ""))
    | [.pane_id, .workspace_id, .tab_id] | @tsv'
}

# Herdr answers `pane neighbor` with the queried pane in `pane_id` and the
# adjacent pane in `neighbor_pane_id`; reading `pane_id` returns the query
# itself and turns the reciprocal check below into a guaranteed mismatch.
pair_neighbor_pane() {  # <session> <direction> <pane>
  "$HERDR" --session "$1" pane neighbor --direction "$2" --pane "$3" 2>/dev/null \
    | jq -r '(.result.neighbor.neighbor_pane_id // .result.neighbor_pane_id) // empty'
}

# Prove one live pair topology from both roles' stable identities and print
# "<driver-pane>\t<navigator-pane>\t<workspace>\t<tab>". On refusal it prints
# the failed invariant instead and returns non-zero, so no caller records a
# topology generation from an unproven pair.
pair_verify_topology() {  # <session> <driver-agent> <driver-copy> <navigator-agent> <navigator-copy>
  local session=$1 dname=$2 dcopy=$3 nname=$4 ncopy=$5
  local drole nrole dp dws dtab np nws ntab left right
  { [ -n "$dname" ] && [ -n "$nname" ] && [ "$dname" != "$nname" ]; } \
    || { printf 'unique role agent targets\n'; return 1; }
  drole=$(pair_resolve_role "$session" "$dname" "$dcopy") || { printf 'driver role identity\n'; return 1; }
  nrole=$(pair_resolve_role "$session" "$nname" "$ncopy") || { printf 'navigator role identity\n'; return 1; }
  IFS=$'\t' read -r dp dws dtab <<<"$drole"
  IFS=$'\t' read -r np nws ntab <<<"$nrole"
  [ "$dp" != "$np" ] || { printf 'distinct role panes\n'; return 1; }
  { [ "$dws" = "$nws" ] && [ "$dtab" = "$ntab" ]; } || { printf 'shared pair tab\n'; return 1; }
  left=$(pair_neighbor_pane "$session" left "$np")
  right=$(pair_neighbor_pane "$session" right "$dp")
  { [ "$left" = "$dp" ] && [ "$right" = "$np" ]; } || { printf 'reciprocal adjacency\n'; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$dp" "$np" "$dws" "$dtab"
}

# fm-spawn records where it PUT each role's pane; composition then moves both
# into the pair workspace and never told the task record. Every consumer that
# resolves a task through state/<id>.meta - fm-send's target resolution, and
# each role reading its own runtime facts - kept seeing a workspace the pair no
# longer occupied.
#
# Both roles of a live pair then diagnosed that exactly backwards: they read
# their own stale meta as current, concluded the PROVEN recovery evidence was
# stale, and blocked a pair whose topology `recover` verified as intact. Writing
# the proven topology back is what keeps the two records from disagreeing.
meta_set() {  # <home> <task-id> <key> <value>
  local home=$1 id=$2 key=$3 value=$4
  local file="$home/state/$id.meta"
  [ -f "$file" ] || return 0
  awk -v k="$key" -v v="$value" 'BEGIN{FS="="} $1==k {print k "=" v; next} {print}' "$file" > "$file.tmp" \
    && mv "$file.tmp" "$file"
}

meta_record_topology() {  # <home> <task-id> <session> <workspace> <tab> <pane>
  meta_set "$1" "$2" window "$3:$6"
  meta_set "$1" "$2" herdr_workspace_id "$4"
  meta_set "$1" "$2" herdr_tab_id "$5"
  meta_set "$1" "$2" herdr_pane_id "$6"
}

# Re-verify a composed pair from each role's stable identity and record the
# proven topology as a new generation. A topology that already matches the
# latest generation is reported as unchanged rather than appended twice, and any
# refusal leaves the recorded topology and the live pair untouched.
pair_recover() {  # <recovery.json>
  local evidence=$1 session dname nname dcopy ncopy topo dp np ws tab generation owner_home
  session=$(jq -r '[.topology_generations[]?.session] | last // empty' "$evidence")
  dname=$(jq -r '.roles.driver.agent_target // empty' "$evidence")
  nname=$(jq -r '.roles.navigator.agent_target // empty' "$evidence")
  dcopy=$(jq -r '.roles.driver.copy // empty' "$evidence")
  ncopy=$(jq -r '.roles.navigator.copy // empty' "$evidence")
  { [ -n "$session" ] && [ -n "$dname" ] && [ -n "$nname" ] && [ -n "$dcopy" ] && [ -n "$ncopy" ]; } \
    || die "recovery evidence records no composed pair topology"
  topo=$(pair_verify_topology "$session" "$dname" "$dcopy" "$nname" "$ncopy") \
    || die "pair topology not recovered: $topo"
  IFS=$'\t' read -r dp np ws tab <<<"$topo"
  jq --arg session "$session" --arg ws "$ws" --arg tab "$tab" --arg dp "$dp" --arg np "$np" \
    --arg da "$dname" --arg na "$nname" \
    '(.topology_generations | last) as $latest
     | (if ($latest.session == $session and $latest.workspace == $ws and $latest.tab == $tab
            and $latest.driver_pane == $dp and $latest.navigator_pane == $np)
        then .
        else .topology_generations += [{
          generation: (([.topology_generations[]?.generation] | max // 0) + 1),
          session:$session,workspace:$ws,tab:$tab,
          driver_pane:$dp,navigator_pane:$np,driver_agent:$da,navigator_agent:$na}]
        end)
     | .roles.driver.pane=$dp | .roles.navigator.pane=$np' "$evidence" > "$evidence.tmp" \
    || die "recovered topology not recorded"
  mv "$evidence.tmp" "$evidence"
  generation=$(jq -r '[.topology_generations[]?.generation] | max // 0' "$evidence")
  # A recovered topology is only half recorded until the task records agree with
  # it; otherwise the next reader of meta repeats the stale-topology misreading.
  owner_home=$(jq -r '.owner_home // empty' "$evidence")
  if [ -n "$owner_home" ]; then
    meta_record_topology "$owner_home" "$(jq -r '.roles.driver.task_id // empty' "$evidence")" \
      "$session" "$ws" "$tab" "$dp"
    meta_record_topology "$owner_home" "$(jq -r '.roles.navigator.task_id // empty' "$evidence")" \
      "$session" "$ws" "$tab" "$np"
  fi
  printf 'paired %s topology generation %s session=%s workspace=%s tab=%s driver=%s navigator=%s\n' \
    "$(jq -r '.pair_id // empty' "$evidence")" "$generation" "$session" "$ws" "$tab" "$dp" "$np"
}

case "${1:-}" in
  send)
    [ "$#" -eq 4 ] || die "send requires <recovery.json> <driver|navigator> <message>"
    evidence=$2; role=$3; message=$4
    [ -f "$evidence" ] || die "recovery evidence is missing"
    case "$role" in driver|navigator) ;; *) die "invalid target role" ;; esac
    # Verified submission through fm-send: a non-zero result means the signal
    # was NOT submitted (failed or unconfirmed), so fail loudly and never retry,
    # inject via Herdr, or fall back to a different message.
    pair_send "$evidence" "$role" "$message" \
      || die "pair signal to $role not sent: submission failed or unconfirmed; no retry, injection, or fallback"
    exit
    ;;
  recover)
    [ "$#" -eq 2 ] || die "recover requires <recovery.json>"
    evidence=$2
    [ -f "$evidence" ] || die "recovery evidence is missing"
    pair_recover "$evidence"
    exit
    ;;
  gate)
    [ "$#" -eq 4 ] || die "gate requires <recovery.json> <gate> <driver-head>"
    evidence=$2; gate=$3; head=$4
    atom "$gate" || die "invalid gate"
    [[ "$head" =~ ^[0-9a-fA-F]{7,64}$ ]] || die "invalid driver HEAD"
    jq --arg gate "$gate" --arg head "$head" '.last_completed_gate=$gate | .current_driver_head=$head' "$evidence" > "$evidence.tmp" || exit 1
    mv "$evidence.tmp" "$evidence"
    exit
    ;;
  finding)
    [ "$#" -eq 4 ] || die "finding requires <recovery.json> open|close <N-id>"
    evidence=$2; action=$3; finding=$4
    [[ "$finding" =~ ^[NQ][1-9][0-9]*$ ]] || die "invalid finding id"
    # shellcheck disable=SC2016 # $finding is a jq variable bound by --arg below.
    case "$action" in
      open) filter='.open_findings = ((.open_findings + [$finding]) | unique)' ;;
      close) filter='.open_findings = [.open_findings[] | select(. != $finding)]' ;;
      *) die "invalid finding action" ;;
    esac
    jq --arg finding "$finding" "$filter" "$evidence" > "$evidence.tmp" || exit 1
    mv "$evidence.tmp" "$evidence"
    exit
    ;;
esac

PAIR_ID=''
PROJECT=''
MODE=''
YOLO=''
TASK_FILE=''
SCOPE_FILE=''
DRIVER_HARNESS=''
DRIVER_MODEL=''
DRIVER_EFFORT=''
NAV_HARNESS=''
NAV_MODEL=''
NAV_EFFORT=''
CONTEXTS=()
CHECKS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pair-id) PAIR_ID=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --yolo) YOLO=$2; shift 2 ;;
    --task-file) TASK_FILE=$2; shift 2 ;;
    --scope-file) SCOPE_FILE=$2; shift 2 ;;
    --driver-harness) DRIVER_HARNESS=$2; shift 2 ;;
    --driver-model) DRIVER_MODEL=$2; shift 2 ;;
    --driver-effort) DRIVER_EFFORT=$2; shift 2 ;;
    --navigator-harness) NAV_HARNESS=$2; shift 2 ;;
    --navigator-model) NAV_MODEL=$2; shift 2 ;;
    --navigator-effort) NAV_EFFORT=$2; shift 2 ;;
    --context) CONTEXTS+=("$2"); shift 2 ;;
    --check) CHECKS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

atom "$PAIR_ID" || die "--pair-id must be a safe task id"
[ -d "$PROJECT" ] || die "--project must be a directory"
case "$MODE" in no-mistakes|direct-PR|local-only) ;; *) die "invalid --mode" ;; esac
case "$YOLO" in on|off) ;; *) die "invalid --yolo" ;; esac
[ -f "$TASK_FILE" ] || die "--task-file is required"
[ -f "$SCOPE_FILE" ] || die "--scope-file is required"
[ -n "$DRIVER_HARNESS" ] || die "--driver-harness is required"
[ -n "$NAV_HARNESS" ] || die "--navigator-harness is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

DRIVER_ID=$PAIR_ID
NAV_ID=$PAIR_ID-nav
PAIR_DIR=$FM_HOME/data/$PAIR_ID
EVIDENCE=$PAIR_DIR/recovery.json
PAIR_LOG=$PAIR_DIR/pair-log.md
READY=$PAIR_DIR/ready
DRIVER_ACK=$PAIR_DIR/driver.ack
NAV_ACK=$PAIR_DIR/navigator.ack
mkdir -p "$PAIR_DIR"
[ ! -e "$EVIDENCE" ] || die "pair evidence already exists: $EVIDENCE"

write_evidence() {
  local state=$1 invariant=${2:-}
  jq -n \
    --arg pair_id "$PAIR_ID" --arg owner_home "$FM_HOME" --arg state "$state" \
    --arg invariant "$invariant" --arg driver_id "$DRIVER_ID" --arg navigator_id "$NAV_ID" \
    --arg log "$PAIR_LOG" --arg project "$(cd "$PROJECT" && pwd -P)" \
    '{schema:1,pair_id:$pair_id,owner_home:$owner_home,state:$state,roles:{driver:{task_id:$driver_id},navigator:{task_id:$navigator_id}},history:$log,project:$project,topology_generations:[],last_completed_gate:null,open_findings:[]} | if ($invariant|length)>0 then .failed_invariant=$invariant else . end' > "$EVIDENCE.tmp"
  mv "$EVIDENCE.tmp" "$EVIDENCE"
}

fail_pair() {
  local invariant=$1
  if [ -f "$EVIDENCE" ]; then
    jq --arg invariant "$invariant" '.state="failed" | .failed_invariant=$invariant' "$EVIDENCE" > "$EVIDENCE.tmp" && mv "$EVIDENCE.tmp" "$EVIDENCE"
  else
    write_evidence failed "$invariant"
  fi
  echo "error: paired-review composition failed: $invariant" >&2
  exit 1
}

write_evidence composing
printf '# Pair %s\n\nDurable reasoning and gate history. Live coordination uses Herdr.\n' "$PAIR_ID" > "$PAIR_LOG"

# shellcheck disable=SC2016 # Backticks here are Markdown code spans in the brief.
render_brief() {
  local id=$1 role=$2 peer=$3 role_skill=$4 peer_role=$5 ack=$6 peer_ack=$7
  "$BRIEF" "$id" "$(basename "$PROJECT")" --mode "$MODE" >/dev/null
  python3 - "$FM_HOME/data/$id/brief.md" "$TASK_FILE" "$SCOPE_FILE" <<'PY'
import pathlib, sys
brief, task, scope = map(pathlib.Path, sys.argv[1:])
text = brief.read_text()
text = text.replace('{TASK}', task.read_text().rstrip())
text = text.replace('{SCOPE}', scope.read_text().rstrip())
brief.write_text(text)
PY
  {
    printf '\n# Paired-review runtime facts\n\n'
    printf 'role=%s\n\n' "$role"
    printf 'Read and follow `%s`. Do not read the parent paired-review skill.\n\n' "$role_skill"
    printf -- '- Pair id: `%s`\n- Peer task id: `%s`\n- Peer role: `%s`\n' "$PAIR_ID" "$peer" "$peer_role"
    printf -- '- Shared durable history: `%s`\n- Recovery evidence: `%s`\n' "$PAIR_LOG" "$EVIDENCE"
    printf -- '- Your barrier acknowledgement: `%s`\n- Peer barrier acknowledgement: `%s`\n- Barrier release: `%s`\n' "$ack" "$peer_ack" "$READY"
    printf -- '- Authoritative current task: `%s`\n' "$TASK_FILE"
    if [ "${#CONTEXTS[@]}" -gt 0 ]; then
      printf -- '- Owner-supplied authoritative parent context:\n'
      printf '  - `%s`\n' "${CONTEXTS[@]}"
      printf '  The current task remains implementation scope; parent sources explain destination and decisions but do not authorize sibling work. Return conflicts to the owner.\n'
    fi
    if [ "${#CHECKS[@]}" -gt 0 ]; then
      printf -- '- Task-specific checks:\n'
      printf '  - %s\n' "${CHECKS[@]}"
    fi
    printf '\nBefore task investigation, create your acknowledgement file and wait until the release file exists, for a bounded five minutes; your role skill owns what to do when that wait runs out.\n'
    printf 'The helper will add exact copy, branch, Herdr pane, and peer agent facts to the recovery evidence before release.\n'
  } >> "$FM_HOME/data/$id/brief.md"
}

render_brief "$DRIVER_ID" driver "$NAV_ID" "/home/dathuynh/codes/firstmate/custom-skills/paired-review/driver/SKILL.md" navigator "$DRIVER_ACK" "$NAV_ACK"
render_brief "$NAV_ID" navigator "$DRIVER_ID" "/home/dathuynh/codes/firstmate/custom-skills/paired-review/navigator/SKILL.md" driver "$NAV_ACK" "$DRIVER_ACK"

spawn_role() {
  local id=$1 harness=$2 model=$3 effort=$4
  set -- "$id" "$PROJECT" --mode "$MODE" --yolo "$YOLO" --harness "$harness" --backend herdr
  [ -z "$model" ] || set -- "$@" --model "$model"
  [ -z "$effort" ] || set -- "$@" --effort "$effort"
  "$SPAWN" "$@"
}
spawn_role "$DRIVER_ID" "$DRIVER_HARNESS" "$DRIVER_MODEL" "$DRIVER_EFFORT" || fail_pair "driver launch"
spawn_role "$NAV_ID" "$NAV_HARNESS" "$NAV_MODEL" "$NAV_EFFORT" || fail_pair "navigator launch"

wait_ack() {
  local until=$((SECONDS + ACK_TIMEOUT))
  while [ "$SECONDS" -lt "$until" ]; do
    [ -f "$DRIVER_ACK" ] && [ -f "$NAV_ACK" ] && return 0
    sleep 0.1
  done
  return 1
}
wait_ack || fail_pair "readiness acknowledgement"

meta_value() { sed -n "s/^$2=//p" "$FM_HOME/state/$1.meta" | head -1; }
DS=$(meta_value "$DRIVER_ID" herdr_session); NS=$(meta_value "$NAV_ID" herdr_session)
DW=$(meta_value "$DRIVER_ID" worktree); NW=$(meta_value "$NAV_ID" worktree)
DB=$(git -C "$DW" branch --show-current); NB=$(git -C "$NW" branch --show-current)
[ -n "$DS" ] && [ "$DS" = "$NS" ] || fail_pair "same Herdr session"
[ "$DW" != "$NW" ] || fail_pair "distinct role copies"
[ "$(git -C "$DW" rev-parse --absolute-git-dir)" != "$(git -C "$NW" rev-parse --absolute-git-dir)" ] || fail_pair "distinct Git directories"
DW=$(cd "$DW" && pwd -P); NW=$(cd "$NW" && pwd -P)

h() { "$HERDR" --session "$DS" "$@"; }
# Every move below reassigns the moved pane's id, and Herdr answers a stale id
# with the pane's CURRENT one, so carrying the launch id forward guarantees a
# mismatch. Each step re-resolves its role from the live agent inventory bound
# to that role's isolated copy instead. Until the role names are published
# the copy is the whole identity, which is why an ambiguous copy refuses here.
DROLE=$(pair_resolve_role "$DS" '' "$DW") || fail_pair "driver role identity"
NROLE=$(pair_resolve_role "$DS" '' "$NW") || fail_pair "navigator role identity"
IFS=$'\t' read -r DP _ _ <<<"$DROLE"
IFS=$'\t' read -r NP _ _ <<<"$NROLE"
h pane move "$DP" --new-workspace --label "pair-$PAIR_ID" --tab-label pair --no-focus >/dev/null || fail_pair "pair workspace creation"
DROLE=$(pair_resolve_role "$DS" '' "$DW") || fail_pair "driver workspace and tab identity"
IFS=$'\t' read -r DP WS TAB <<<"$DROLE"
h pane move "$NP" --tab "$TAB" --split right --target-pane "$DP" --no-focus >/dev/null || fail_pair "navigator topology move"
NROLE=$(pair_resolve_role "$DS" '' "$NW") || fail_pair "navigator pane identity"
IFS=$'\t' read -r NP _ _ <<<"$NROLE"
h pane rename "$DP" driver >/dev/null || fail_pair "driver role label"
h pane rename "$NP" navigator >/dev/null || fail_pair "navigator role label"
DRIVER_TARGET="$PAIR_ID-driver"; NAV_TARGET="$PAIR_ID-navigator"
h agent rename "$DP" "$DRIVER_TARGET" >/dev/null || fail_pair "driver agent identity"
h agent rename "$NP" "$NAV_TARGET" >/dev/null || fail_pair "navigator agent identity"
TOPO=$(pair_verify_topology "$DS" "$DRIVER_TARGET" "$DW" "$NAV_TARGET" "$NW") || fail_pair "$TOPO"
IFS=$'\t' read -r DP NP WS TAB <<<"$TOPO"
# The moves above reassigned both panes; tell each task record where its role
# actually lives now, so meta and the recovery evidence cannot disagree.
meta_record_topology "$FM_HOME" "$DRIVER_ID" "$DS" "$WS" "$TAB" "$DP"
meta_record_topology "$FM_HOME" "$NAV_ID" "$DS" "$WS" "$TAB" "$NP"

DHEAD=$(git -C "$DW" rev-parse HEAD); NHEAD=$(git -C "$NW" rev-parse HEAD)
SOURCE_REV=$(git -C "$ROOT" rev-parse HEAD)
# shellcheck disable=SC2016 # Backticks here are Markdown code spans in the brief.
for role_id in "$DRIVER_ID" "$NAV_ID"; do
  {
    printf '\n## Verified pair composition\n\n'
    printf -- '- Driver copy and branch: `%s` at `%s`\n' "$DW" "$DB"
    printf -- '- Navigator copy and branch: `%s` at `%s`\n' "$NW" "$NB"
    printf -- '- Pair topology session/workspace/tab: `%s` / `%s` / `%s`\n' "$DS" "$WS" "$TAB"
  } >> "$FM_HOME/data/$role_id/brief.md"
done
jq \
  --arg session "$DS" --arg ws "$WS" --arg tab "$TAB" \
  --arg dp "$DP" --arg np "$NP" --arg da "$DRIVER_TARGET" --arg na "$NAV_TARGET" \
  --arg dw "$DW" --arg nw "$NW" --arg db "$DB" --arg nb "$NB" --arg dh "$DHEAD" --arg nh "$NHEAD" \
  --arg driver_skill "$ROOT/custom-skills/paired-review/driver/SKILL.md" \
  --arg navigator_skill "$ROOT/custom-skills/paired-review/navigator/SKILL.md" --arg source_revision "$SOURCE_REV" \
  '.state="ready" | del(.failed_invariant)
   | .roles.driver += {copy:$dw,branch:$db,head:$dh,pane:$dp,agent_target:$da,skill:$driver_skill,skill_source_revision:$source_revision}
   | .roles.navigator += {copy:$nw,branch:$nb,head:$nh,pane:$np,agent_target:$na,skill:$navigator_skill,skill_source_revision:$source_revision}
   | .topology_generations += [{generation:1,session:$session,workspace:$ws,tab:$tab,driver_pane:$dp,navigator_pane:$np,driver_agent:$da,navigator_agent:$na}]' \
  "$EVIDENCE" > "$EVIDENCE.tmp" && mv "$EVIDENCE.tmp" "$EVIDENCE"
# The barrier both roles actually wait on is the release FILE; the readiness
# messages only point at the evidence. Publish the barrier FIRST, then notify.
#
# The old order did the opposite and made an unconfirmable notification fatal to
# a pair whose composition had fully verified. Submission cannot be confirmed
# for a worker that is already mid-turn on several harnesses, and both roles are
# mid-turn by construction here - they are sitting in the barrier wait. So the
# release aborted between its two sends, leaving the driver notified, the
# navigator never told, and no release file: a pair that had passed every
# invariant, destroyed by its own announcement.
#
# Notification stays honest: an unconfirmed send is recorded as unconfirmed,
# never as delivered. It is written into the evidence so each role can announce
# degraded coverage rather than stall on it.
: > "$READY"
release_note() {  # <role>
  local role=$1
  if pair_send "$EVIDENCE" "$role" "PAIR READY $PAIR_ID; read verified runtime facts in $EVIDENCE"; then
    printf 'confirmed'
  else
    printf 'unconfirmed'
  fi
}
DRIVER_NOTIFY=$(release_note driver)
NAV_NOTIFY=$(release_note navigator)
jq --arg d "$DRIVER_NOTIFY" --arg n "$NAV_NOTIFY" \
  '.release_notifications = {driver:$d, navigator:$n}' "$EVIDENCE" > "$EVIDENCE.tmp" \
  && mv "$EVIDENCE.tmp" "$EVIDENCE"
if [ "$DRIVER_NOTIFY" != confirmed ] || [ "$NAV_NOTIFY" != confirmed ]; then
  printf 'warning: pair %s released, but readiness notification was unconfirmed (driver=%s navigator=%s); both roles are released by the barrier file and must read the recovery evidence themselves\n' \
    "$PAIR_ID" "$DRIVER_NOTIFY" "$NAV_NOTIFY" >&2
fi
printf 'paired %s ready session=%s workspace=%s tab=%s driver=%s navigator=%s\n' "$PAIR_ID" "$DS" "$WS" "$TAB" "$DRIVER_TARGET" "$NAV_TARGET"
