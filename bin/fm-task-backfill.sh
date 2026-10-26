#!/usr/bin/env bash
# Backfill old task sources without changing them; see --help for the command contract.
set -euo pipefail
exec node "$(dirname "${BASH_SOURCE[0]}")/fm-task-backfill-lib.mjs" "$@"
