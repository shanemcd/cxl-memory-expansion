#!/usr/bin/env python3
"""Capture memory-tier metrics from a cluster's Prometheus-compatible API.

Records every tier-level signal (see the recording rules in
examples/recording-rules.yaml) as one JSON snapshot on stdout. Designed for
OpenShift-style clusters, where the platform Prometheus is queried through
the Thanos Querier route with a short-lived service-account token.

Requirements:
  - oc, authenticated as a user that can create service-account tokens in
    openshift-monitoring and read routes there
  - the memory-tier recording rules applied (examples/recording-rules.yaml)

Usage:
  ./capture-metrics.py > snapshot.json

Optional environment (for hosts without direct DNS/trust for the route):
  THANOS_CACERT  path to a CA bundle that verifies the route certificate
  THANOS_RESOLVE host:port:ip curl --resolve override for the route host
"""

import datetime
import json
import os
import subprocess
import sys
import urllib.parse

OC = "oc"  # on PATH; set KUBECONFIG as needed

QUERIES = {
    "dram_ratio": "node:memory_dram_used:ratio",
    "dram_anon_ratio": "node:memory_dram_anon:ratio",
    "cxl_ratio": "node:memory_cxl_used:ratio",
    "spill_ratio": "node:memory_spilled:ratio",
    "pgdemote_rate": "node:memory_pgdemote:rate5m",
    "pgpromote_rate": "node:memory_pgpromote:rate5m",
    "vm_resident": "vmi:memory_tier_resident_bytes:sum",
    "vm_spill": "vmi:memory_spilled:ratio",
    "vm_demote_rate": "vmi:memory_pgdemote:rate5m",
    "alerts": 'ALERTS{alertname=~"MemoryTier.*"}',
}


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    token = run(OC, "create", "token", "-n", "openshift-monitoring",
                "prometheus-k8s", "--duration=1h")
    host = run(OC, "-n", "openshift-monitoring", "get", "route",
               "thanos-querier", "-o", "jsonpath={.spec.host}")

    out = {"captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "thanos_host": host}
    for name, q in QUERIES.items():
        url = f"https://{host}/api/v1/query?query={urllib.parse.quote(q)}"
        cmd = ["curl", "-s"]
        if os.environ.get("THANOS_CACERT"):
            cmd += ["--cacert", os.environ["THANOS_CACERT"]]
        if os.environ.get("THANOS_RESOLVE"):
            cmd += ["--resolve", os.environ["THANOS_RESOLVE"]]
        cmd += ["-H", f"Authorization: Bearer {token}", url]
        r = subprocess.run(cmd, capture_output=True, text=True)
        try:
            d = json.loads(r.stdout)
            out[name] = [
                {"labels": {k: v for k, v in x["metric"].items()
                            if k not in ("job", "instance", "prometheus")},
                 "value": x["value"][1]}
                for x in d.get("data", {}).get("result", [])
            ]
        except Exception as e:  # noqa: BLE001 - record and continue
            out[name] = f"error: {e}"
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
