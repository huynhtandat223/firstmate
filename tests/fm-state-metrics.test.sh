#!/usr/bin/env bash
# Metric rules through the public CLI, with distinct events and overlapping invariants.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-state-metrics)
trap fm_test_cleanup EXIT
cat > "$TMP_ROOT/trace" <<'EOF'
{"at":1,"seq":10,"id":"a","state":"in_flight","meta":false,"held":false,"status_at":1,"turn_end_at":1,"tester":"none","approved":false}
{"at":1,"seq":10,"id":"b","state":"queued","meta":true,"held":false,"status_at":1,"turn_end_at":1,"tester":"verified","approved":false}
{"at":2,"seq":14,"id":"a","state":"in_flight","meta":true,"held":true,"status_at":2,"turn_end_at":2,"tester":"none","approved":true}
{"at":2,"seq":14,"id":"b","state":"queued","meta":true,"held":false,"status_at":1,"turn_end_at":2,"tester":"verified","approved":false}
EOF
cat > "$TMP_ROOT/shadow" <<'EOF'
{"at":1,"items":[{"id":"a","key":"hold:a","open":true},{"id":"b","key":"plan:b","open":false}],"cards":[{"id":"b","key":"plan:b"}]}
EOF
check_metrics() {
  "$1/fm-state-metrics" --trace "$TMP_ROOT/trace" --shadow "$TMP_ROOT/shadow" > "$TMP_ROOT/out" &&
    jq -e '.MR1.D == 4 and .MR1.U == 3 and .MR1.value == 0.25 and .MR2.count == 1 and .MR2.ids[0].id == "b" and .MR3.count == 6 and .MR3.taskSamples == 4 and .MR3.divergentTaskSamples == 4 and .MR3.firstWithoutMeta == ["a"] and .MR4.count == 1 and .MR4.ids[0].id == "a" and .MR5.count == 1 and .MR5.ids[0].id == "b"' "$TMP_ROOT/out" >/dev/null
}
check_metrics "$ROOT/bin"
# Each removed metric rule must make the public-output assertion fail.
mkdir "$TMP_ROOT/mutant"
cp "$ROOT/bin/fm-task-sources-lib.mjs" "$TMP_ROOT/mutant/"
for rule in 'unique.add(key)' 'violations.push' "rules.push('in-flight-without-meta')" "rules.push('meta-without-in-flight')" "rules.push('held-in-flight')" "rules.push('verified-without-approval')" "rules.push('approved-in-flight')" 'misses.push' 'stale.push'; do
  cp "$ROOT/bin/fm-state-metrics" "$TMP_ROOT/mutant/fm-state-metrics"
  python3 - "$TMP_ROOT/mutant/fm-state-metrics" "$rule" <<'PY'
import sys
p,rule=sys.argv[1:]
s=open(p).read()
if rule.endswith('.push'):
    s=s.replace(rule+'(', 'void (')
else:
    s=s.replace(rule, 'void 0')
open(p,'w').write(s)
PY
  if check_metrics "$TMP_ROOT/mutant"; then fail "insensitive metric rule: $rule"; fi
done
echo 'ok - MR1 to MR5, ids, and nine sensitivity controls'
