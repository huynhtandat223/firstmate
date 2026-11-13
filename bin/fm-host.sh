#!/usr/bin/env bash
# Machine registry and cross-machine home ownership. See --help.
set -euo pipefail
exec node "$(dirname "${BASH_SOURCE[0]}")/fm-host-lib.mjs" "$@"
