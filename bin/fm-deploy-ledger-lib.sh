#!/usr/bin/env bash
# Shared deploy ledger API access. Source this file; no persistent local ledger is authoritative.
# fm_deploy_ledger_call <fm-task deploy-ledger arguments...> uses this home's task-shadow settings.
# fm_deploy_ledger_snapshot <output> reads a complete ordered JSONL snapshot, atomically.
FM_DEPLOY_LEDGER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fm_deploy_ledger_call() (
  . "$FM_DEPLOY_LEDGER_DIR/fm-task-shadow-config-lib.sh"
  fm_task_shadow_config "${FM_CONFIG_OVERRIDE:-${CONFIG:-${FM_HOME:?}/config}}/task-shadow"
  "${FM_DEPLOY_LEDGER_TASK:-$FM_DEPLOY_LEDGER_DIR/fm-task.sh}" deploy-ledger "$@"
)
fm_deploy_ledger_snapshot() {
  local tmp
  tmp=$(mktemp "${1}.XXXXXX") || return 1
  if ! fm_deploy_ledger_call list > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$1"
}
fm_deploy_ledger_write() { # <append|put-cursor> <json>
  local tmp rc=0
  tmp=$(mktemp) || return 1
  printf '%s\n' "$2" > "$tmp"
  fm_deploy_ledger_call "$1" --file "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}
