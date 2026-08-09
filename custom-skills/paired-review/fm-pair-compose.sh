#!/usr/bin/env bash
# Compose two ordinary Firstmate task launches into one verified Herdr pair.
#
# Usage: fm-pair-compose.sh --pair-id ID --project DIR --mode MODE --yolo on|off
#   --task-file FILE --scope-file FILE
#   --driver-harness NAME [--driver-model NAME] [--driver-effort LEVEL]
#   --navigator-harness NAME [--navigator-model NAME] [--navigator-effort LEVEL]
#   [--context SOURCE]... [--check TEXT]...
#   fm-pair-compose.sh send <recovery.json> <driver|navigator> <message>
#   fm-pair-compose.sh gate <recovery.json> <gate> <driver-head>
#   fm-pair-compose.sh finding <recovery.json> open|close <N-id>
#
# The task and scope files are owner-supplied authority. Context values are
# pointers, not copied requirements. The helper creates <ID> and <ID>-nav through
# fm-spawn.sh, waits for both role barrier acknowledgements, composes their Herdr
# panes, verifies role identity and reciprocal adjacency, writes recovery.json,
# and releases the barrier. It never changes generic fm-spawn behavior.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FM_HOME=${FM_HOME:-$ROOT}
SPAWN=${FM_PAIR_SPAWN:-$ROOT/bin/fm-spawn.sh}
BRIEF=${FM_PAIR_BRIEF:-$ROOT/bin/fm-brief.sh}
HERDR=${FM_PAIR_HERDR:-herdr}
ACK_TIMEOUT=${FM_PAIR_ACK_TIMEOUT:-30}

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }
atom() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

case "${1:-}" in
  send)
    [ "$#" -eq 4 ] || die "send requires <recovery.json> <driver|navigator> <message>"
    evidence=$2; role=$3; message=$4
    [ -f "$evidence" ] || die "recovery evidence is missing"
    case "$role" in driver|navigator) ;; *) die "invalid target role" ;; esac
    session=$(jq -r '.topology_generations[-1].session // empty' "$evidence")
    target=$(jq -r --arg role "$role" '.roles[$role].agent_target // empty' "$evidence")
    [ -n "$session" ] && [ -n "$target" ] || die "recovery evidence lacks a live target"
    "$HERDR" --session "$session" agent send "$target" "$message"
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
    printf '\nBefore task investigation, create your acknowledgement file and wait until the release file exists.\n'
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
DP=$(meta_value "$DRIVER_ID" herdr_pane_id); NP=$(meta_value "$NAV_ID" herdr_pane_id)
[ -n "$DS" ] && [ "$DS" = "$NS" ] || fail_pair "same Herdr session"
[ -n "$DP" ] && [ -n "$NP" ] || fail_pair "role pane identity"
[ "$DW" != "$NW" ] || fail_pair "distinct role copies"
[ "$(git -C "$DW" rev-parse --absolute-git-dir)" != "$(git -C "$NW" rev-parse --absolute-git-dir)" ] || fail_pair "distinct Git directories"

h() { "$HERDR" --session "$DS" "$@"; }
h pane move "$DP" --new-workspace --label "pair-$PAIR_ID" --tab-label pair --no-focus >/dev/null || fail_pair "pair workspace creation"
DINFO=$(h pane get "$DP") || fail_pair "driver pane verification"
WS=$(printf '%s' "$DINFO" | jq -r '.result.pane.workspace_id // empty')
TAB=$(printf '%s' "$DINFO" | jq -r '.result.pane.tab_id // empty')
[ -n "$WS" ] && [ -n "$TAB" ] || fail_pair "driver workspace and tab identity"
h pane move "$NP" --tab "$TAB" --split right --target-pane "$DP" --no-focus >/dev/null || fail_pair "navigator topology move"
h pane rename "$DP" driver >/dev/null || fail_pair "driver role label"
h pane rename "$NP" navigator >/dev/null || fail_pair "navigator role label"
DRIVER_TARGET="$PAIR_ID-driver"; NAV_TARGET="$PAIR_ID-navigator"
h agent rename "$DP" "$DRIVER_TARGET" >/dev/null || fail_pair "driver agent identity"
h agent rename "$NP" "$NAV_TARGET" >/dev/null || fail_pair "navigator agent identity"
DINFO=$(h pane get "$DP"); NINFO=$(h pane get "$NP")
printf '%s' "$DINFO" | jq -e --arg ws "$WS" --arg tab "$TAB" '.result.pane.workspace_id==$ws and .result.pane.tab_id==$tab' >/dev/null || fail_pair "driver topology"
printf '%s' "$NINFO" | jq -e --arg ws "$WS" --arg tab "$TAB" '.result.pane.workspace_id==$ws and .result.pane.tab_id==$tab' >/dev/null || fail_pair "navigator topology"
LEFT=$(h pane neighbor --direction left --pane "$NP" | jq -r '.result.pane.pane_id // .result.neighbor.pane_id // empty')
RIGHT=$(h pane neighbor --direction right --pane "$DP" | jq -r '.result.pane.pane_id // .result.neighbor.pane_id // empty')
[ "$LEFT" = "$DP" ] && [ "$RIGHT" = "$NP" ] || fail_pair "reciprocal adjacency"
DA=$(h agent get "$DRIVER_TARGET" | jq -r '.result.pane.pane_id // .result.agent.pane_id // empty')
NA=$(h agent get "$NAV_TARGET" | jq -r '.result.pane.pane_id // .result.agent.pane_id // empty')
[ "$DA" = "$DP" ] && [ "$NA" = "$NP" ] && [ "$DRIVER_TARGET" != "$NAV_TARGET" ] || fail_pair "unique role agent targets"

DHEAD=$(git -C "$DW" rev-parse HEAD); NHEAD=$(git -C "$NW" rev-parse HEAD)
SOURCE_REV=$(git -C "$ROOT" rev-parse HEAD)
for role_id in "$DRIVER_ID" "$NAV_ID"; do
  {
    printf '\n## Verified pair composition\n\n'
    printf -- '- Driver copy and branch: `%s` at `%s`\n' "$DW" "$DB"
    printf -- '- Navigator copy and branch: `%s` at `%s`\n' "$NW" "$NB"
    printf -- '- Driver Herdr target: `%s`\n- Navigator Herdr target: `%s`\n' "$DRIVER_TARGET" "$NAV_TARGET"
    printf -- '- Herdr session/workspace/tab: `%s` / `%s` / `%s`\n' "$DS" "$WS" "$TAB"
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
h agent send "$DRIVER_TARGET" "PAIR READY $PAIR_ID; read verified runtime facts in $EVIDENCE" >/dev/null || fail_pair "driver readiness release"
h agent send "$NAV_TARGET" "PAIR READY $PAIR_ID; read verified runtime facts in $EVIDENCE" >/dev/null || fail_pair "navigator readiness release"
: > "$READY"
printf 'paired %s ready session=%s workspace=%s tab=%s driver=%s navigator=%s\n' "$PAIR_ID" "$DS" "$WS" "$TAB" "$DRIVER_TARGET" "$NAV_TARGET"
