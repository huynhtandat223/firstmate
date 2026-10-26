#!/usr/bin/env bash
# Compare old sources with the shadow record; never repair either source.
set -euo pipefail
exec node "$(dirname "${BASH_SOURCE[0]}")/fm-task-reconcile-lib.mjs" "$@"
