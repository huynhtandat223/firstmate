#!/usr/bin/env bash
# fm-task-links.sh - publish durable task review URLs and screenshot paths.
# Usage: fm-task-links.sh <id> add-url <http(s)-url> [label]
#        fm-task-links.sh <id> add-image <absolute-raster-path> [label]
#        fm-task-links.sh <id> show [--json]
# Records: $FM_HOME/data/<id>/links.json, schema fm-task-links.v1.
# links[] holds {url,label}; images[] holds {path,label}. Keep the newest 12
# unique URLs and 6 unique images. Re-publishing moves an item to the end.
# Paths must be absolute PNG/JPEG/GIF/WebP/AVIF paths; missing files are allowed
# so the board can disclose gaps. Board build owns copying and byte validation.
# Records survive task cleanup alongside the retained brief and scout report.
# show adds purpose (first nonblank Captain's intent line, title fallback in the
# snapshot) and outcome (newest captain-relevant event via fm-classify-lib.sh).
# Malformed records refuse rather than presenting partial materials.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
fail() { printf 'error: %s\nhelp: fm-task-links.sh --help\n' "$1"; exit "${2:-1}"; }
case " $* " in *' --help '*|*' -h '*) usage; exit 0 ;; esac
[ "$#" -ge 1 ] || { usage; exit 2; }
id=$1; shift
[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$id" != . ] && [ "$id" != .. ] || fail 'invalid task id' 2
cmd=${1:-show}; [ "$#" -eq 0 ] || shift
case "$cmd" in
  show) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --json ]; } || fail 'show accepts only --json' 2 ;;
  add-url|add-image) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'supply a value and optional label' 2 ;;
  *) fail "unknown command: $cmd" 2 ;;
esac
record="$FM_HOME/data/$id/links.json"
validate() {
  jq -e '
    def text: type == "string" and length > 0 and length <= 2048 and (test("[[:cntrl:]]") | not);
    def url: text and test("^https?://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$");
    def image: text and startswith("/") and test("\\.(png|jpe?g|gif|webp|avif)$"; "i");
    .schema == "fm-task-links.v1"
    and (.links | type == "array" and length <= 12)
    and (.images | type == "array" and length <= 6)
    and all(.links[]; (.url | url) and (.label | text))
    and all(.images[]; (.path | image) and (.label | text))
  ' "$1" >/dev/null 2>&1
}
if [ -e "$record" ]; then
  validate "$record" || fail "invalid materials record for $id"
  data=$(jq -c . "$record")
else
  data='{"schema":"fm-task-links.v1","links":[],"images":[]}'
fi
if [ "$cmd" != show ]; then
  value=$1; label=${2:-$value}
  if [ "$cmd" = add-url ]; then field=links; key=url; cap=12; else field=images; key=path; cap=6; fi
  mkdir -p "$(dirname "$record")"
  tmp=$(mktemp "$record.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$data" | jq --arg field "$field" --arg key "$key" --arg value "$value" --arg label "$label" --argjson cap "$cap" '
    .[$field] = ([.[$field][] | select(.[$key] != $value)] + [{($key):$value,label:$label}])[-$cap:]
  ' > "$tmp"
  validate "$tmp" || fail 'invalid URL, image path, or label' 2
  mv "$tmp" "$record"
  printf 'task: %s\npublished: %s\nhelp: fm-task-links.sh %s show\n' "$id" "$cmd" "$id"
  exit 0
fi
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
purpose=$(awk '/^## Captain.s intent$/ {intent=1; next} intent && /^#/ {exit} intent && /[^[:space:]]/ {print; exit}' "$FM_HOME/data/$id/brief.md" 2>/dev/null || true)
outcome=''
if [ -f "$FM_HOME/state/$id.status" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    if status_is_captain_relevant "$line"; then outcome=$(status_line_note "$line"); fi
  done < "$FM_HOME/state/$id.status"
fi
data=$(printf '%s\n' "$data" | jq --arg purpose "$purpose" --arg outcome "$outcome" '. + {purpose:$purpose,outcome:$outcome}')
if [ "${1:-}" = --json ]; then printf '%s\n' "$data"; else
  printf '%s\n' "$data" | jq -r '
    "purpose: " + (.purpose | tojson), "outcome: " + (.outcome | tojson),
    "links[\(.links | length)]{url,label}:", (.links[] | "  " + ([.url,.label] | map(tojson) | join(","))),
    "images[\(.images | length)]{path,label}:", (.images[] | "  " + ([.path,.label] | map(tojson) | join(",")))'
fi
