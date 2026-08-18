#!/usr/bin/env bash
# fm-sync-status.sh - read-only fork/upstream content-sync status.
#
# Usage: fm-sync-status.sh [--json] [<repository>]
#
# Reads only existing Git refs and commit metadata. It never fetches or changes
# the working tree or any ref. Run it from the firstmate repository root, or
# pass a repository path explicitly.
set -eu

json=0
repo="${PWD}"
for arg in "$@"; do
  case "$arg" in
    --json) json=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) printf 'error: unknown option: %s\n' "$arg" >&2; exit 2 ;;
    *) repo=$arg ;;
  esac
done
repo=$(cd "$repo" 2>/dev/null && pwd -P) || { printf 'error: repository not found: %s\n' "$repo" >&2; exit 2; }
git_cmd=(git -C "$repo")
root=$("${git_cmd[@]}" rev-parse --show-toplevel 2>/dev/null) || { printf 'error: not a Git repository: %s\n' "$repo" >&2; exit 2; }
ref_hash() { "${git_cmd[@]}" rev-parse --verify "$1^{commit}" 2>/dev/null || printf '%s' ''; }
local_hash=$(ref_hash main)
origin_hash=$(ref_hash origin/main)
upstream_hash=$(ref_hash upstream/main)
[ -n "$local_hash" ] && local_tree=$("${git_cmd[@]}" rev-parse "$local_hash^{tree}") || local_tree=''
[ -n "$origin_hash" ] && origin_tree=$("${git_cmd[@]}" rev-parse "$origin_hash^{tree}") || origin_tree=''
if [ -n "$local_tree" ] && [ -n "$origin_tree" ]; then
  content_match=$([ "$local_tree" = "$origin_tree" ] && echo true || echo false)
else content_match=null
fi
receipt_hash=''; receipt_subject=''; receipt_source='upstream/main'
receipt_hash=$("${git_cmd[@]}" log main --first-parent --format='%H%x09%s' --grep='Sync fork with upstream main' --grep='Integrate .* upstream commits' -i -n 1 2>/dev/null || true)
if [ -n "$receipt_hash" ]; then receipt_subject=${receipt_hash#*$'\t'}; receipt_hash=${receipt_hash%%$'\t'*}; fi
if [ -n "$local_hash" ] && [ -n "$upstream_hash" ]; then
  read -r ahead behind < <("${git_cmd[@]}" rev-list --left-right --count "$local_hash...$upstream_hash")
else ahead=null; behind=null; fi
if [ "$json" -eq 1 ]; then
  printf '{"schema":"fm-sync-status.v1","repository":"%s","local_main":"%s","origin_main":"%s","local_matches_origin":%s,"upstream_main":"%s","latest_sync_receipt":{"commit":"%s","subject":"%s","source_ref":"%s"},"ancestry":{"local_vs_upstream":{"ahead":%s,"behind":%s},"interpretation":"ancestry counts are not a content-sync verdict after squash-style sync; compare commit trees"}}\n' \
    "$root" "$local_hash" "$origin_hash" "$content_match" "$upstream_hash" "$receipt_hash" "$receipt_subject" "$receipt_source" "$ahead" "$behind"
  exit 0
fi
printf 'fork content: '; if [ "$content_match" = true ]; then printf 'local main matches origin/main\n'; else printf 'local main does not match origin/main\n'; fi
printf 'origin/main: %s\n' "${origin_hash:-missing}"
printf 'upstream/main: %s\n' "${upstream_hash:-missing}"
if [ -n "$receipt_hash" ]; then printf 'latest sync receipt: %s %s (source: %s)\n' "$receipt_hash" "$receipt_subject" "$receipt_source"; else printf 'latest sync receipt: unavailable from current main history\n'; fi
printf 'ancestry local main vs upstream/main: ahead=%s behind=%s\n' "$ahead" "$behind"
printf 'interpretation: ancestry counts are not a content-sync verdict after squash-style sync; compare commit trees.\n'
