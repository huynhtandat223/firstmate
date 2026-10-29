#!/usr/bin/env bash
# Brief names the evidence (spec huynhtandat223/firstmate#217, ticket #218, G3).
# Log-only first: bin/fm-enforce-lib.sh owns the switch, check brief-verify.
#
# fm_brief_verify_check <task-id> <brief-file> is called by bin/fm-brief.sh
# --check. When the brief's `# Acceptance` section names an issue of
# huynhtandat223/cfw-modules, it reads that issue's user-visible scenario pages
# with bin/fm-acceptance.mjs parse, maps each page to a verify-cfw feature
# through the `pages:` line of the feature files at origin/main of the cfw-modules
# clone (git show, read only), and requires `verify-cfw run <feature>` in the
# brief for each mapped feature:
#   missing-verify  a hit: the brief does not name the run for a mapped feature.
#   unmapped        logged, never a hit: no feature file lists the page, which is
#                   every page until the feature files reach origin/main.
# An issue with only internal scenarios, or a brief with no cfw-modules issue,
# logs nothing. Returns 1 only for a hit while config/enforce-brief-verify
# holds `block`; otherwise a hit is a line in state/enforce-brief-verify.log and
# a "would refuse:" line on stderr.
#
# Inputs: FM_HOME, FM_ROOT, STATE and CONFIG (bin/fm-brief.sh sets them), and FM_BRIEF_CFW_CLONE for a clone other than
# $FM_HOME/projects/cfw-modules. FM_ACCEPTANCE_GH names another gh command, as
# bin/fm-acceptance.mjs reads it.

BRIEF_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-enforce-lib.sh
. "$BRIEF_VERIFY_DIR/fm-enforce-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$BRIEF_VERIFY_DIR/fm-brief-heading-lib.sh"

FM_BRIEF_VERIFY_CFW_ISSUE='https://github.com/huynhtandat223/cfw-modules/issues/[0-9]+'
FM_BRIEF_VERIFY_FEATURE_DIR=.agents/skills/verify-cfw/features

# The page id a scenario's `page:` field names: its first backticked token, or
# the whole value when it has none. A value of `-` names no page.
fm_brief_verify_page_id() {  # <page field>
  local field=$1
  if [[ "$field" =~ \`([^\`]+)\` ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [ "$field" != - ] && [ -n "$field" ]; then
    printf '%s\n' "$field"
  fi
}

# Prints "<feature><TAB><page>" for every page each feature file at origin/main
# lists on its `pages:` line.
fm_brief_verify_feature_pages() {  # <clone>
  local clone=$1 path name line page pages
  [ -d "$clone" ] || return 0
  while IFS= read -r path; do
    name=${path##*/}
    name=${name%.md}
    [ "$name" != README ] || continue
    line=$(git -C "$clone" show "origin/main:$path" 2>/dev/null | sed -n '/^pages:/{p;q;}') || continue
    pages=${line#pages:}
    while IFS= read -r page; do
      page=${page#"${page%%[![:space:]]*}"}
      page=${page%"${page##*[![:space:]]}"}
      [ -z "$page" ] || printf '%s\t%s\n' "$name" "$page"
    done < <(printf '%s\n' "$pages" | tr ',' '\n')
  done < <(git -C "$clone" ls-tree --name-only "origin/main" "$FM_BRIEF_VERIFY_FEATURE_DIR/" 2>/dev/null | grep '\.md$' || true)
}

# True when the brief names `verify-cfw run <feature>`, alone or in a comma list.
fm_brief_verify_names_run() {  # <brief> <feature>
  grep -Eq "verify-cfw[[:space:]]+(--[[:space:]]+)?run[[:space:]]+([A-Za-z0-9_-]+,)*$2([^A-Za-z0-9_-]|\$)" "$1"
}

fm_brief_verify_check() {  # <task-id> <brief-file>
  local task=$1 brief=$2 home=${FM_HOME:?} root=${FM_ROOT:?}
  local config=${CONFIG:-${FM_CONFIG_OVERRIDE:-$home/config}} state=${STATE:-${FM_STATE_OVERRIDE:-$home/state}}
  local clone=${FM_BRIEF_CFW_CLONE:-$home/projects/cfw-modules}
  local section issue json pages page id features map feature missing='' mode text
  section=$(fm_brief_heading_body "$brief" "# Acceptance" 2>/dev/null) || return 0
  issue=$(printf '%s\n' "$section" | grep -oE "$FM_BRIEF_VERIFY_CFW_ISSUE" | head -1) || true
  [ -n "$issue" ] || return 0
  command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  json=$(node "$root/bin/fm-acceptance.mjs" parse "$issue" 2>/dev/null) || true
  [ -n "$json" ] || return 0
  pages=$(printf '%s' "$json" \
    | jq -r '.scenarios[]? | select(.surface == "user-visible") | .page // ""' 2>/dev/null | sort -u) || return 0
  map=$(fm_brief_verify_feature_pages "$clone")
  features=
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    feature=$(printf '%s\n' "$map" | awk -F'\t' -v p="$id" '$2 == p { print $1 }' | sort -u)
    if [ -z "$feature" ]; then
      fm_enforce_log "$state" brief-verify skip unmapped "$task: no verify-cfw feature lists page $id ($issue)"
      continue
    fi
    features="${features:+$features
}$feature"
  done < <(while IFS= read -r page; do fm_brief_verify_page_id "$page"; done <<< "$pages" | sort -u)
  while IFS= read -r feature; do
    [ -n "$feature" ] || continue
    fm_brief_verify_names_run "$brief" "$feature" || missing="${missing:+$missing, }$feature"
  done < <(printf '%s\n' "$features" | sort -u)
  [ -n "$missing" ] || return 0
  text="the brief for $task names no \`verify-cfw run <feature>\` for: $missing; name the run (npm run verify-cfw -- run <feature> --target storybook:<branch> --widths 1440,390 --json --out data/$task/) in the brief"
  mode=$(fm_enforce_mode "$config" brief-verify)
  if [ "$mode" = block ]; then
    fm_enforce_log "$state" brief-verify refuse missing-verify "$text"
    printf 'refused: missing-verify %s\n' "$text" >&2
    return 1
  fi
  fm_enforce_log "$state" brief-verify would-refuse missing-verify "$text"
  printf 'would refuse: missing-verify %s\n' "$text" >&2
  return 0
}
