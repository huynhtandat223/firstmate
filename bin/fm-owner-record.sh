#!/usr/bin/env bash
# fm-owner-record.sh - file-oriented bridge to fm-task.sh owner-record.
# Usage: fm-owner-record.sh hold-read binding|reconcile ID
#        fm-owner-record.sh hold-write binding|reconcile ID FILE [active|inactive]
# Payloads are retained verbatim; inactive records read as absent.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd=${1:-}
case "$cmd" in
  hold-read)
    [ "$#" -eq 3 ] || exit 2
    row=$("$SELF_DIR/fm-task.sh" owner-record hold get --home "${FM_BACKLOG_HOME:-main}" --kind "$2" --identity "$3")
    python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["payload"],end="") if r and r.get("state")=="active" else None' <<<"$row"
    ;;
  hold-write)
    [ "$#" -ge 4 ] && [ "$#" -le 5 ] || exit 2
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    python3 - "$2" "$3" "$4" "${5:-active}" "${FM_BACKLOG_HOME:-main}" >"$tmp" <<'PY'
import datetime,json,pathlib,sys
kind,identity,file,state,home=sys.argv[1:]
if kind not in ('binding','reconcile') or state not in ('active','inactive'): raise SystemExit(2)
print(json.dumps(dict(home=home,kind=kind,sourceId=identity,taskId=identity if kind=='reconcile' else None,payload=pathlib.Path(file).read_text(),state=state,at=datetime.datetime.now(datetime.timezone.utc).isoformat())))
PY
    "$SELF_DIR/fm-task.sh" owner-record hold put --home "${FM_BACKLOG_HOME:-main}" --kind "$2" --identity "$3" --file "$tmp" >/dev/null
    ;;
  *) printf 'Usage: fm-owner-record.sh hold-read KIND ID | hold-write KIND ID FILE [active|inactive]\n'; exit 2 ;;
esac
