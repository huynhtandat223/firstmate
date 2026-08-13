#!/usr/bin/env bash
# fm-supervisor-brief.sh - scaffold the programme supervisor's brief at
# data/<programme-id>/brief.md under the active firstmate home.
#
# This lives in custom-skills/ on purpose. bin/fm-spawn.sh --supervisor owns the
# generic temporary-supervisor LIFECYCLE (leased home, relaunch, cleanup gates);
# what that session is actually for is programme policy, and policy stays here.
# A different programme discipline can ship its own brief writer without
# touching core.
#
# Usage:
#   fm-supervisor-brief.sh <programme-id>
#
# Writes the contract and leaves {TASK} and {SCOPE} for the caller to fill:
#   {TASK}   the programme, its authorization, and the pointer to
#            custom-skills/orchestrator/PROGRAMME.md
#   {SCOPE}  the boundary this programme may not widen without the captain
#
# Refuses to overwrite an existing brief. Absolute paths only, because the
# session reads them from a different home than the one that wrote them.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_SKILLS="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$CUSTOM_SKILLS/.." && pwd)}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
ID=$1
case "$ID" in
  ''|*[!A-Za-z0-9._-]*) echo "error: programme id must be a privacy-safe slug: $ID" >&2; exit 2 ;;
esac

# The declared-external-wait verb has one owner; read it rather than copying it.
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_ROOT/bin/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
STATUS_FILE=$(shell_quote "$STATE/$ID.status")

cat > "$BRIEF" <<EOF
You are the programme supervisor: one firstmate session running its own isolated home for one authorized programme. Work on your own; do not wait for a human.

# Task
{TASK}

# Scope and seams
{SCOPE}

# Your home
This worktree IS your own firstmate home. It is leased to you, it carries a \`.fm-supervisor-home\` identity marker, and it survives if you die - a relaunch brings you back to this same home and this same child inventory.
Run \`bin/fm-session-start.sh\` from it once at session start. Your own \`state/\`, \`data/\`, and \`config/\` live here, you hold your own session lock, and you run your own supervision cycle over your own workers.
You have no project clones of your own and you must not create any.
The parent firstmate home's clones under \`$PROJECTS\` are READ-ONLY allocation sources. Name one by absolute path when you spawn a worker so the worker gets its own isolated copy; never edit, branch, commit in, or re-clone the source itself.
This home is disposable. Everything that must outlive the programme goes to the parent home's \`$DATA/$ID/\`, and \`$DATA/$ID/report.md\` is your deliverable.

# Rules
1. You coordinate; you do not implement. Delegate every ticket to an ordinary worker through the normal brief, spawn, status, steer, and cleanup lifecycle. One ticket, one worker, one branch, explicit custody. Do not invent a second delegation system.
2. Each ticket keeps its project's ordinary delivery path and the captain's ordinary merge authority. Never merge anything and never push to a default branch.
3. The captain talks to you directly in this session. Your workers report to YOU and never address the captain; you are their only channel outward, exactly as the main firstmate is yours.
4. Stay inside this home. The only things you write outside it are the programme records under \`$DATA/$ID/\` and the status file below.
5. Report to the main firstmate by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Append sparingly: a material programme phase change, a captain decision, a real blocker, a failure, or work ready for captain review. Your workers' routine churn stays inside this home and never reaches that file.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - when the programme is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need help.
6. If a decision belongs above you - scope beyond the authorized programme, a destructive, irreversible, or security-sensitive action, or an ask-user finding - append \`needs-decision: {summary of options}\` and stop.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it.
   When a blocker or wait clears with no reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. On relaunch, reconcile the workers already recorded in this home's \`state/\` BEFORE dispatching anything. A ticket that already has a worker never gets a second one.

# Programme records
Your decision records, ledger, and report belong to the parent home, not to this disposable one.
The unresolved-decision machinery is keyed to the parent home too, so name it explicitly rather than letting it resolve against your own:
   \`FM_HOME=$FM_HOME $FM_ROOT/bin/fm-decision-hold.sh <command> $ID ...\`
Read \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` for what those commands mean and when they are required.

# Definition of done
Cleanup of this session refuses until all four of these hold, so treat them as the finish line:
1. No child worker record is left in this home's \`state/\` - every ticket is landed or explicitly excluded with its reason, and every worker is cleaned up.
2. This home holds no unlanded work of its own.
3. Every decision you opened is resolved or durably held.
4. \`$DATA/$ID/report.md\` exists and stands alone: what the programme delivered, what it excluded and why, the evidence, and what remains.
Pass the shared completion gate in \`decision-hold-lifecycle\`, then append \`done: {one-line conclusion}\` to the status file and stop. Firstmate handles cleanup.
EOF
echo "scaffolded: $BRIEF (programme supervisor; replace {TASK} and {SCOPE})"
