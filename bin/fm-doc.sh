#!/usr/bin/env bash
# Publish committed shared docs to 5001 and keep this home's private material there; see --help of each part.
#   git documents:     fm-doc.sh publish|diff|list|get|materialize --repo ...   (bin/fm-doc-lib.mjs, --help)
#   private material:  fm-doc.sh seed|status|sync|put|remove|materialize --home NAME   (bin/fm-material-lib.mjs, --help)
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  seed|status|sync|put|remove) exec node "$SCRIPT_DIR/fm-material-lib.mjs" "$@" ;;
  materialize)
    for arg in "$@"; do
      [ "$arg" != "--repo" ] || exec node "$SCRIPT_DIR/fm-doc-lib.mjs" "$@"
    done
    exec node "$SCRIPT_DIR/fm-material-lib.mjs" "$@" ;;
  material-help) exec node "$SCRIPT_DIR/fm-material-lib.mjs" --help ;;
esac
exec node "$SCRIPT_DIR/fm-doc-lib.mjs" "$@"
