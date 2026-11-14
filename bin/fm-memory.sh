#!/usr/bin/env bash
# Memory on 5001; see --help for commands and configuration.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-memory-lib.mjs" "$@"
