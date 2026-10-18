#!/usr/bin/env bash
# End-to-end verification of the CXL memory expansion MVP on the lab cluster.
#
# Verifies, in order:
#   1. the exporter's parsers (unit tests, no cluster needed)
#   2. the deployed exporter DaemonSet is Ready on every node
#   3. the tier-aware descheduler Deployment is Available
#   4. the recording rules and alerts are loaded in platform Prometheus
#   5. every recording-rule family and the exporter's raw metrics return
#      live series from the monitoring API
#
# Usage:  KUBECONFIG=... OC=/path/to/oc ./verify.sh
# Lab-host conveniences (route DNS/CA quirks) are honored via the same
# environment variables as demo/capture-metrics.py.
set -euo pipefail

OC="${OC:-oc}"
EXPORTER_REPO="${EXPORTER_REPO:-$(cd "$(dirname "$0")/../../memory-tier-exporter" && pwd)}"
FAIL=0

say()  { printf '%s\n' "$*"; }
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; FAIL=1; }

echo "== 1. exporter unit tests"
if (cd "$EXPORTER_REPO" && go test ./... >/dev/null 2>&1); then
  pass "go test ./... in memory-tier-exporter"
else
  fail "go test ./... in memory-tier-exporter"
fi

echo "== 2. exporter DaemonSet"
DESIRED=$($OC -n cxl-observability get ds memory-tier-exporter -o jsonpath='{.status.desiredNumberScheduled}')
READY=$($OC -n cxl-observability get ds memory-tier-exporter -o jsonpath='{.status.numberReady}')
if [ "$DESIRED" = "$READY" ] && [ "$DESIRED" != "0" ]; then
  pass "memory-tier-exporter ready on $READY/$DESIRED nodes"
else
  fail "memory-tier-exporter ready $READY/$DESIRED"
fi

echo "== 3. tier-aware descheduler"
AVAIL=$($OC -n cxl-observability get deploy tier-descheduler -o jsonpath='{.status.availableReplicas}')
[ "$AVAIL" = "1" ] && pass "tier-descheduler available" || fail "tier-descheduler available=$AVAIL"

echo "== 4. PrometheusRules loaded"
for rule in memory-tier-recording-rules memory-tier-alerts; do
  if $OC -n cxl-observability get prometheusrule "$rule" >/dev/null 2>&1; then
    pass "PrometheusRule $rule exists"
  else
    fail "PrometheusRule $rule missing"
  fi
done

echo "== 5. live series from the monitoring API"
TOKEN=$($OC create token -n openshift-monitoring prometheus-k8s --duration=1h)
HOST=$($OC -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')
query() {
  local q="$1"
  local cmd=(curl -s -H "Authorization: Bearer $TOKEN"
             "https://${HOST}/api/v1/query?query=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$q")")
  if [ -n "${THANOS_CACERT:-}" ]; then cmd+=(--cacert "$THANOS_CACERT"); fi
  if [ -n "${THANOS_RESOLVE:-}" ]; then cmd+=(--resolve "$THANOS_RESOLVE"); fi
  "${cmd[@]}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data",{}).get("result",[])))'
}
check_series() {
  local name="$1" q="$2" min="${3:-1}"
  local n; n=$(query "$q")
  if [ "${n:-0}" -ge "$min" ]; then
    pass "$name ($n series)"
  else
    fail "$name ($n series, wanted >= $min)"
  fi
}
# A recording rule can be healthy yet produce no series when its inputs are
# legitimately empty (e.g. no workload is currently spilled), so rules that
# only materialize under memory pressure are checked for rule health, not
# series presence. A rule whose expression fails to evaluate reports
# health != ok and fails this check.
check_rule() {
  local name="$1" want="$2"
  local cmd=(curl -s -H "Authorization: Bearer $TOKEN" "https://${HOST}/api/v1/rules")
  if [ -n "${THANOS_CACERT:-}" ]; then cmd+=(--cacert "$THANOS_CACERT"); fi
  if [ -n "${THANOS_RESOLVE:-}" ]; then cmd+=(--resolve "$THANOS_RESOLVE"); fi
  local health; health=$("${cmd[@]}" | python3 -c '
import json,sys
want = sys.argv[1]
d = json.load(sys.stdin)
for g in d.get("data", {}).get("groups", []):
    for r in g.get("rules", []):
        if r.get("name") == want:
            print(r.get("health"))
            sys.exit(0)
print("missing")' "$want")
  if [ "$health" = "ok" ]; then
    pass "rule health: $want"
  else
    fail "rule health: $want (health: $health)"
  fi
}
check_series "exporter up"              'up{job="memory-tier-exporter"}' 3
check_series "tier nodes"               'node_memory_tier_nodes' 3
check_series "per-node tier memory"     'node_memory_tier_memtotal_bytes' 3
check_series "per-node anon (THP incl)" 'node_memory_tier_anon_bytes' 3
check_series "demotion counters"        'node_memory_tier_pgdemote_total' 3
check_series "rule: dram used ratio"    'node:memory_dram_used:ratio' 3
check_series "rule: dram anon ratio"    'node:memory_dram_anon:ratio' 3
check_series "rule: cxl used ratio"     'node:memory_cxl_used:ratio' 1
check_series "rule: spill ratio"        'node:memory_spilled:ratio' 1
check_series "rule: demote rate"        'node:memory_pgdemote:rate5m' 3
check_series "workload attribution"     'node_memory_tier_workload_anon_bytes' 1
check_series "rule: workload resident"  'workload:memory_tier_resident_bytes:sum' 1
check_rule   "rule: workload spill"     'workload:memory_spilled:ratio'
check_series "rule: workload demote rate" 'workload:memory_pgdemote:rate5m' 1
check_series "alerts defined"           'ALERTS{alertname=~"MemoryTier.*"}' 1

echo
if [ "$FAIL" = "0" ]; then
  say "ALL CHECKS PASSED"
else
  say "SOME CHECKS FAILED"
fi
exit "$FAIL"
