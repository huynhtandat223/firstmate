#!/usr/bin/env bash
# Project registry CLI. The client header owns commands and cache behavior.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-project-lib.mjs" "$@"
