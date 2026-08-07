#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
skills="$ROOT/.agents/skills"
roles="$ROOT/.agents/roles"
for path in "$skills/firstmate-coding-guidelines/SKILL.md" "$skills/firstmate-codexapp/SKILL.md" "$skills/firstmate-orca/SKILL.md" "$skills/paired-review/SKILL.md"; do
  [ -r "$path" ] || fail "primary operational skill is not discoverable: $path"
done
for role in driver navigator worker planner orchestrator; do
  find "$roles/$role" -type f -print -quit | grep -q . || fail "missing role contract: $role"
done
find "$skills" -path '*/planner/*' -o -path '*/orchestrator/*' | grep -q . && fail "worker role contract remained discoverable"
pass "primary skills remain discoverable while role contracts are explicit only"
