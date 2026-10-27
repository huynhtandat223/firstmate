#!/usr/bin/env bash
# Shared allowlist for the shadow writer and backfill service settings.
# fm_task_shadow_config <flag-file> exports only supported task API settings.
fm_task_shadow_config() {
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FM_TASK_BASE_URL=*|FM_TASK_AUTH=*|FM_TASK_TOKEN_FILE=*) export "${line?}" ;;
    esac
  done < "$1"
}
