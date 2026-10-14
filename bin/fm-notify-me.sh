#!/usr/bin/env bash
# notify-me: post owner notifications and read decisions on Dev 5001.
# Usage:
#   fm-notify-me.sh post --producer NAME --dedupe KEY --title TEXT --body TEXT
#     [--severity info|warning|error] [--link URL] [--action ID:LABEL] (up to 3)
#   fm-notify-me.sh decision ID [--producer NAME]
#   fm-notify-me.sh --help
# Environment: FM_NOTIFY_BASE_URL (default http://127.0.0.1:5001),
#   FM_NOTIFY_RECIPIENT (required unless $FM_HOME/config/notify-recipient exists),
#   FM_NOTIFY_PRODUCER (decision token selector, default firstmate).
# Tokens: ~/.local/share/cfw-scripts-private/notify-NAME.token; regular private
#   files only (no group/other permissions). Tokens never enter command arguments.
# post stdout: notification UUID (201 or UNIQUE_KEY_CONFLICT 409).
# decision stdout: compact JSON decision record, or nothing when not yet decided.
# Exit: 0 success, 1 transport/API/credential error, 2 invalid arguments.
# Dependencies: bash, curl, jq, stat. Requests have a 30-second timeout.
# Actions use one atomic deep insert; retry does not change existing content.
set -euo pipefail
usage() { grep '^#' "$0" | head -n 21 | cut -c 3-; }
error() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
[[ ${1:-} != --help ]] || { usage; exit 0; }
command=${1:-}; [[ -n $command ]] || { usage; exit 2; }; shift
producer=${FM_NOTIFY_PRODUCER:-firstmate}; dedupe='' title='' body='' severity=info link=''
actions='[]'; id=; body_set=0; producer_set=0
case "$command" in
  post) ;;
  decision) [[ ${1:-} != --help ]] || { usage; exit 0; }; [[ $# -gt 0 && $1 != -* ]] || error 'decision requires an id' 2; id=$1; shift ;;
  *) error 'expected post or decision; use --help' 2 ;;
esac
while [[ $# -gt 0 ]]; do
  flag=$1; shift
  [[ $flag != --help ]] || { usage; exit 0; }
  case "$flag" in
    --producer|--dedupe|--title|--body|--severity|--link|--action)
      [[ $# -gt 0 ]] || error "$flag requires a value" 2
      value=$1; shift ;;
    *) error "unknown argument $flag; use --help" 2 ;;
  esac
  [[ $command != decision || $flag == --producer ]] || error "$flag is not valid for decision" 2
  case "$flag" in
    --producer) producer=$value; producer_set=1 ;;
    --dedupe) dedupe=$value ;;
    --title) title=$value ;;
    --body) body=$value; body_set=1 ;;
    --severity) severity=$value ;;
    --link) link=$value ;;
    --action)
      [[ $value == *:* && -n ${value%%:*} && -n ${value#*:} ]] || error 'action must be ID:LABEL' 2
      actions=$(jq -c --arg id "${value%%:*}" --arg label "${value#*:}" '. + [{actionId:$id,label:$label}]' <<< "$actions") ;;
  esac
done
[[ $producer =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || error 'invalid producer name' 2
uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ $command == post ]]; then
  [[ $producer_set == 1 && -n $dedupe && -n $title && $body_set == 1 ]] || error 'post requires --producer, --dedupe, --title and --body' 2
  [[ $severity == info || $severity == warning || $severity == error ]] || error 'severity must be info, warning or error' 2
  jq -e 'length <= 3 and (map(.actionId) | length == (unique | length)) and all(.[]; (.actionId|length)<=64 and (.label|length)<=200)' <<< "$actions" >/dev/null || error 'at most three distinct bounded actions are allowed' 2
  [[ ${#dedupe} -le 200 && ${#title} -le 200 && ${#body} -le 8000 && ${#link} -le 2048 ]] || error 'notification text exceeds field limits' 2
else
  [[ $id =~ $uuid ]] || error 'decision id must be a UUID' 2
fi
base=${FM_NOTIFY_BASE_URL:-http://127.0.0.1:5001}; base=${base%/}
[[ $base == http://* || $base == https://* ]] || error 'base URL must use http or https' 2
token_file=$HOME/.local/share/cfw-scripts-private/notify-$producer.token
[[ -f $token_file && ! -L $token_file && -O $token_file ]] || error 'producer token must be an owned regular private file'
mode=$(stat -c '%a' "$token_file" 2>/dev/null || stat -f '%Lp' "$token_file")
[[ $mode =~ ^[0-7]*00$ ]] || error 'producer token must have no group or other permissions'
token=$(<"$token_file")
[[ -n $token && $token != *$'\n'* && $token != *$'\r'* && $token != *'"'* && $token != *\\\\* ]] || error 'invalid token file'
umask 077
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# curl reads the credential from stdin, not argv or a persistent config file.
request() {
  local method=$1 url=$2
  local args=()
  [[ $method != POST ]] || args=(--data-binary @"$work/payload")
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -q --config - --silent --globoff --max-time 30 --request "$method" \
      --header 'Content-Type: application/json' --output "$work/response" \
      --write-out '%{http_code}' "${args[@]}" "$url"
}
if [[ $command == post ]]; then
  recipient=${FM_NOTIFY_RECIPIENT:-}
  if [[ -z $recipient && -n ${FM_HOME:-} && -f $FM_HOME/config/notify-recipient ]]; then
    recipient=$(<"$FM_HOME/config/notify-recipient")
  fi
  [[ -n $recipient ]] || error "set FM_NOTIFY_RECIPIENT or configure \$FM_HOME/config/notify-recipient" 2
  jq -cn --arg recipient "$recipient" --arg dedupe "$dedupe" --arg title "$title" \
    --arg body "$body" --arg severity "$severity" --arg link "$link" --argjson actions "$actions" \
    '{recipient:$recipient,kind:"notification",dedupeKey:$dedupe,title:$title,body:$body,severity:$severity,actions:$actions} + (if $link=="" then {} else {link:$link} end)' > "$work/payload"
  status=$(request POST "$base/api/notification") || error 'notification request could not complete; retry with the same dedupe key'
  case "$status" in
    201) result=$(jq -er '.id // .data.id' "$work/response") || error 'create response omitted notification id' ;;
    409) result=$(jq -er 'select(.errorCode=="UNIQUE_KEY_CONFLICT") | .details.existingId' "$work/response") || error 'conflict did not identify the existing notification' ;;
    *) error "notification request refused (HTTP $status)" ;;
  esac
  [[ $result =~ $uuid ]] || error 'response notification id was invalid'
  printf '%s\n' "$result"
else
  status=$(request GET "$base/api/notification_decision?\$filter=notificationId%20eq%20$id&\$top=1") || error 'decision request could not complete'
  [[ $status == 200 ]] || error "decision request refused (HTTP $status)"
  jq -e '(.value|type)=="array"' "$work/response" >/dev/null 2>&1 || error 'invalid decision response'
  jq -c '.value[0] // empty' "$work/response"
fi
