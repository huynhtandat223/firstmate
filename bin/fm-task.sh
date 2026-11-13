#!/usr/bin/env bash
# fm-task.sh - the one writer and reader of the task contract on Dev 5001.
#
# Every firstmate, worker, and assistance writes the task record and reads it back through this command.
# `fm-task.sh --help` prints the commands, the transitions, the exit codes, and the environment;
# bin/fm-task-lib.mjs is the owner of that contract and of the projection from events to the task row.
set -eu

command -v node >/dev/null 2>&1 || { echo 'fm-task: node is required' >&2; exit 2; }
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# A worker's absolute command path identifies the supervising home when launch
# environment carries only FM_TASK_ID. Explicit FM_HOME remains authoritative.
export FM_HOME="${FM_HOME:-$(dirname "$DIR")}"
if [ "${1:-}" = steers ]; then
  # The absolute supervising-home command also selects its portable API settings.
  # shellcheck source=bin/fm-task-shadow-config-lib.sh
  . "$DIR/fm-task-shadow-config-lib.sh"
  fm_task_shadow_config "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/task-shadow"
fi
exec node "$DIR/fm-task-lib.mjs" "$@"
