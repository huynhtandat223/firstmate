#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
roles="$ROOT/.agents/roles"
skills="$ROOT/.agents/skills"
discovered=$(find "$skills" -name SKILL.md -print | sort)
case "$discovered" in *"$roles"*) fail "role contract entered skill discovery";; esac
for path in "$roles/planner/contract/SKILL.md" "$roles/orchestrator/contract/SKILL.md" "$roles/navigator/paired-review/SKILL.md"; do
  [ -r "$path" ] || fail "explicit role contract is unreadable: $path"
done
pass "role contracts stay out of automatic skill discovery and remain readable by explicit path"
