#!/usr/bin/env bash
# Resolve a model's context handoff threshold from a home-local config file.
# Usage: fm-handoff-threshold.sh <config-file> <model> [recorded-value]
# A recorded value preserves the task's original resolution on relaunch.
set -eu
if [ -n "${3:-}" ]; then
  printf '%s\n' "$3"
  exit 0
fi
if [ -f "$1" ]; then
  while read -r pattern value extra; do
    case "$pattern" in ''|'#'*) continue ;; esac
    # Model patterns intentionally use shell glob matching.
    # shellcheck disable=SC2254
    case "$2" in
      $pattern)
        if [ -n "$extra" ] || ! [[ "$value" = off || "$value" =~ ^([1-9]|[1-9][0-9]|100)$ ]]; then
          echo "error: invalid handoff threshold for $pattern: $value" >&2
          exit 1
        fi
        printf '%s\n' "$value"
        exit 0
        ;;
    esac
  done < "$1"
fi
printf '40\n'
