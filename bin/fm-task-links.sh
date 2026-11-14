#!/usr/bin/env bash
# fm-task-links.sh - publish task review URLs and screenshot bytes to 5001.
# Usage: fm-task-links.sh <id> add-url <http(s)-url> [label]
#        fm-task-links.sh <id> add-image <absolute-raster-path> [label]
#        fm-task-links.sh <id> show [--json]
#        fm-task-links.sh <id> migrate
# Records: $FM_HOME/data/<id>/links.json, schema fm-task-links.v1.
# links[] holds {url,label}; images[] holds {path,label}. Keep the newest 12
# unique URLs and 6 unique images. Re-publishing moves an item to the end.
# New images must be readable absolute PNG/JPEG/GIF/WebP files, 1 byte to 2 MiB.
# Legacy missing paths remain readable in the cache; new publication rejects them.
# Configured 5001 writes carry one key per publication; a failed write keeps its key in
# links-pending/ so a rerun retries that publication, and a later republish is a new event.
# Images carry a stable material id from the publishing path; readers keep the newest.
# migrate backs up the record and image files in links-backups/, then publishes the
# local URLs (by URL and label) and images (by bytes and label) that 5001 does not yet hold.
# The backup directory is mode 0700 with 0600 files.
# show reads 5001 first and materializes images locally; an outage uses the cache.
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
  migrate) [ "$#" -eq 0 ] || fail 'migrate takes no arguments' 2 ;;
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
# One key per publication. The pending file holds the nonce of an unfinished publication,
# named by its identity (command, value, label, and image bytes); a retry reuses it, and
# changed bytes or a new label start a new publication. Callers remove the file on success.
pending_file() { printf '%s/data/%s/links-pending/%s' "$FM_HOME" "$id" "$(printf '%s' "$1:$2:$3:${4:-}" | shasum -a 256 | awk '{print $1}')"; }
publication_key() {
  local pending nonce
  pending=$(pending_file "$@")
  if [ -s "$pending" ]; then nonce=$(cat "$pending"); else
    mkdir -p "$(dirname "$pending")"; chmod 700 "$(dirname "$pending")"
    nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    (umask 077; printf '%s' "$nonce" > "$pending")
  fi
  printf 'materials-%s' "$(printf '%s' "$id:$1:$2:$3:${4:-}:$nonce" | shasum -a 256 | awk '{print $1}')"
}
material_id() { printf 'image-%s' "$(printf '%s' "$id:$1" | shasum -a 256 | awk '{print $1}')"; }
if [ "$cmd" = add-url ] || [ "$cmd" = add-image ]; then
  value=$1; label=${2:-$value}
  if [ "$cmd" = add-image ]; then
    [ -f "$value" ] && [ -s "$value" ] && [ "$(wc -c < "$value")" -le 2097152 ] || fail 'image must exist and contain 1 byte to 2 MiB' 2
    [ "${#label}" -le 200 ] || fail 'image label exceeds 200 characters' 2
    [[ "${value,,}" =~ \.(png|jpe?g|gif|webp)$ ]] || fail 'supported image suffixes: png jpg jpeg gif webp' 2
    perl -e 'open my $f,"<",$ARGV[0] or exit 1; binmode $f; read $f,my $h,16; exit(($h =~ /^\x89PNG\r\n\x1a\n/ || $h =~ /^\xff\xd8\xff/ || $h =~ /^GIF8[79]a/ || $h =~ /^RIFF....WEBP/s) ? 0 : 1)' "$value" || fail 'unsupported raster bytes' 2
  fi
  if [ "$cmd" = add-url ]; then field=links; key=url; cap=12; else field=images; key=path; cap=6; fi
  mkdir -p "$(dirname "$record")"
  if [ -f "$record" ]; then
    backup="$FM_HOME/data/$id/links-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
    mkdir -p "$(dirname "$backup")"
    cp "$record" "$backup"
  fi
  tmp=$(mktemp "$record.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$data" | jq --arg field "$field" --arg key "$key" --arg value "$value" --arg label "$label" --argjson cap "$cap" '
    .[$field] = ([.[$field][] | select(.[$key] != $value)] + [{($key):$value,label:$label}])[-$cap:]
  ' > "$tmp"
  validate "$tmp" || fail 'invalid URL, image path, or label' 2
  mv "$tmp" "$record"
  shadow_config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/task-shadow"
  {
    # shellcheck source=bin/fm-task-shadow-config-lib.sh
    . "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
    if [ -e "$shadow_config" ]; then fm_task_shadow_config "$shadow_config"; fi
    {
      digest=''
      [ "$cmd" = add-image ] && digest=$(shasum -a 256 "$value" | awk '{print $1}')
      pubkey=$(publication_key "$cmd" "$value" "$label" "$digest")
      if [ "$cmd" = add-url ]; then
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task.sh" event "$id" link --url "$value" --note "$label" --key "$pubkey" || exit $?
      else
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task.sh" comment "$id" --image "$value" --image-label "$label" --material "$(material_id "$value")" --key "$pubkey" || exit $?
      fi
      rm -f "$(pending_file "$cmd" "$value" "$label" "$digest")"
    }
  }
  printf 'task: %s\npublished: %s\nhelp: fm-task-links.sh %s show\n' "$id" "$cmd" "$id"
  exit 0
fi
if [ "$cmd" = migrate ]; then
  [ -f "$record" ] || fail "no local materials record for $id"
  shadow_config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/task-shadow"
  # shellcheck source=bin/fm-task-shadow-config-lib.sh
  . "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
  if [ -e "$shadow_config" ]; then fm_task_shadow_config "$shadow_config"; fi
  remote=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task.sh" materials "$id") || fail "cannot read 5001 materials for $id"
  # The backup holds protected screenshot bytes: private directory, private files.
  umask 077
  backup="$FM_HOME/data/$id/links-backups/migrate-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$backup/images"; chmod 700 "$backup" "$backup/images"
  cp "$record" "$backup/links.json"
  # Missing legacy images are recorded, never dropped: they stay in links.json.
  remote_file=$(mktemp "$backup/remote.XXXXXX")
  printf '%s' "$remote" > "$remote_file"
  todo=$(FM_REMOTE_FILE="$remote_file" FM_BACKUP="$backup" node -e '
    const fs=require("fs"),path=require("path"),crypto=require("crypto");
    const local=JSON.parse(fs.readFileSync(process.argv[1],"utf8")),remote=JSON.parse(fs.readFileSync(process.env.FM_REMOTE_FILE,"utf8"));
    const sha=b=>crypto.createHash("sha256").update(b).digest("hex");
    const have=new Set(remote.images.map(r=>sha(Buffer.from(r.content,"base64"))+":"+r.label));
    const urls=new Set(remote.links.map(r=>r.url+"\n"+r.label));
    const out=[];
    for(const r of local.links) if(!urls.has(r.url+"\n"+r.label)) out.push({kind:"url",value:r.url,label:r.label});
    for(const r of local.images){
      let b; try{ b=fs.readFileSync(r.path); }catch{ out.push({kind:"skip",value:r.path,label:r.label}); continue; }
      fs.writeFileSync(path.join(process.env.FM_BACKUP,"images",sha(r.path).slice(0,16)+path.extname(r.path)),b,{mode:0o600});
      if(!have.has(sha(b)+":"+r.label)) out.push({kind:"image",value:r.path,label:r.label});
    }
    console.log(JSON.stringify(out));
  ' "$record") || { rm -f "$remote_file"; fail 'cannot compare local and 5001 materials'; }
  rm -f "$remote_file"
  published=0 skipped=0 status=0
  while IFS=$'\t' read -r kind value label; do
    case "$kind" in
      url)
        pubkey=$(publication_key add-url "$value" "$label")
        if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task.sh" event "$id" link --url "$value" --note "$label" --key "$pubkey" >/dev/null; then
          rm -f "$(pending_file add-url "$value" "$label")"; published=$((published + 1))
        else status=1; fi ;;
      image)
        digest=$(shasum -a 256 "$value" | awk '{print $1}')
        pubkey=$(publication_key add-image "$value" "$label" "$digest")
        if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task.sh" comment "$id" --image "$value" --image-label "$label" --material "$(material_id "$value")" --key "$pubkey" >/dev/null; then
          rm -f "$(pending_file add-image "$value" "$label" "$digest")"; published=$((published + 1))
        else status=1; fi ;;
      skip) skipped=$((skipped + 1)); printf 'skipped: %s (image unreadable; kept in links.json)\n' "$value" >&2 ;;
    esac
  done < <(printf '%s' "$todo" | jq -r '.[] | [.kind,.value,.label] | @tsv')
  printf 'task: %s\nmigrated: %s\nskipped: %s\nbackup: %s\n' "$id" "$published" "$skipped" "$backup"
  exit "$status"
fi
# Read durable records first; materialize bytes into this home's disposable cache.
shadow_config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/task-shadow"
{
  # shellcheck source=bin/fm-task-shadow-config-lib.sh
  . "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
  if [ -e "$shadow_config" ]; then fm_task_shadow_config "$shadow_config"; fi
  if remote=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-task.sh" materials "$id"); then
    cache="$FM_HOME/data/$id/material-images"
    mkdir -p "$cache"
    # shellcheck disable=SC2016
    remote=$(printf '%s' "$remote" | FM_MATERIAL_CACHE="$cache" node -e '
      const fs=require("fs"),path=require("path");
      const v=JSON.parse(fs.readFileSync(0,"utf8"));
      const types={"image/png":"png","image/jpeg":"jpg","image/gif":"gif","image/webp":"webp"};
      v.images=v.images.map(r=>{ const ext=types[r.mediaType]; if(!ext) throw Error("unsupported image type"); const p=path.join(process.env.FM_MATERIAL_CACHE,`${r.seq}-${r.position}.${ext}`); const b=Buffer.from(r.content,"base64"); if(!b.length || b.length>2097152) throw Error("invalid image size"); fs.writeFileSync(p,b,{mode:0o600}); return {path:p,label:r.label}; });
      console.log(JSON.stringify(v));
    ') || fail 'invalid remote materials'
    data=$(printf '%s' "$data" | FM_REMOTE_MATERIALS="$remote" node -e '
      const fs=require("fs"),crypto=require("crypto");
      const v=JSON.parse(fs.readFileSync(0,"utf8")),remote=JSON.parse(process.env.FM_REMOTE_MATERIALS);
      const key=r=>{try{return crypto.createHash("sha256").update(fs.readFileSync(r.path)).digest("hex")+":"+r.label;}catch{return r.path+":"+r.label;}};
      const keys=new Set(remote.images.map(key)); v.images=v.images.filter(r=>!keys.has(key(r))); console.log(JSON.stringify(v));
    ')
    data=$(printf '%s' "$data" | jq --argjson remote "$remote" '
      .links = (reduce (.links + $remote.links)[] as $r ([]; [.[] | select(.url != $r.url)] + [$r]))[-12:]
      | .images = (reduce (.images + $remote.images)[] as $r ([]; [.[] | select(.path != $r.path)] + [$r]))[-6:]')
    cache_tmp=$(mktemp "$cache/materials.XXXXXX")
    printf '%s\n' "$data" > "$cache_tmp"
    mv "$cache_tmp" "$cache/materials.json"
  else
    if [ -f "$FM_HOME/data/$id/material-images/materials.json" ]; then
      cached="$FM_HOME/data/$id/material-images/materials.json"
      validate "$cached" || fail 'invalid remote materials cache'
      data=$(jq -c . "$cached")
    fi
    printf 'warning: 5001 unavailable; using materials cache: %s (modified %s)\n' "$record" "$(date -r "$record" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)" >&2
  fi
}
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
