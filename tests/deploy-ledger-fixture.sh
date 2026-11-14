#!/usr/bin/env bash
# Controlled API boundary for pre-existing shell cases. Its storage stays test-owned.
set -euo pipefail
[ "$1" = deploy-ledger ] || exit 2
shift
action=$1; shift
store="${FM_HOME:?}/data/deploy-verify"
mkdir -p "$store"
file=
while [ "$#" -gt 0 ]; do case "$1" in --file) file=$2; shift 2 ;; *) shift ;; esac; done
case "$action" in
  list) [ ! -f "$store/ledger.jsonl" ] || cat "$store/ledger.jsonl" ;;
  cursor) [ ! -f "$store/state.json" ] || cat "$store/state.json" ;;
  append) cat "$file" >> "$store/ledger.jsonl" ;;
  put-cursor) cp "$file" "$store/state.json" ;;
  *) exit 2 ;;
esac
