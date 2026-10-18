# Demonstrating the memory-tier observability loop

`capture-metrics.py` records every tier-level signal from the cluster's
Prometheus-compatible query API in one JSON snapshot:

- `node:memory_dram_used:ratio` — DRAM utilization per node
- `node:memory_dram_anon:ratio` — anonymous (working-set) DRAM utilization
- `node:memory_cxl_used:ratio` — slower-tier utilization per node
- `node:memory_spilled:ratio` — share of used memory below DRAM
- `node:memory_pgdemote:rate5m` — page demotion rate
- `workload:memory_tier_resident_bytes:sum`, `workload:memory_spilled:ratio`,
  `workload:memory_pgdemote:rate5m` — per-workload tier attribution
  (KubeVirt VMs under the default preset)

It expects an OpenShift-style cluster with the recording rules from
[examples/recording-rules.yaml](../examples/recording-rules.yaml) applied and
`oc` authenticated as a user that can create service-account tokens in
`openshift-monitoring` (the script mints a short-lived token for the platform
Prometheus's service account to query the monitoring API).

The `demo-evidence/` directory holds one recorded run of the full scenario,
on a three-node cluster whose CXL node is emulated (DRAM NUMA node 0, CXL
NUMA node 1, kernel memory tiers 4 and 22):

| Phase | What was done | What the metrics showed |
|---|---|---|
| `phase0-baseline` | VM running on the CXL node, no pressure | DRAM 72% used, all VM memory on DRAM, zero demotion |
| `phaseA-vm-demote` | Bounded reclaim of 150 MiB from the VM's cgroup | Exactly 150 MiB of the VM's cold guest pages moved to CXL; VM kept running; per-VM spill ratio 0.77; per-VM demotion rate visible |
| `phaseB-before/after` | 2.6 GiB cold-memory workload on the node, then a bounded 2 GiB global reclaim | DRAM 98% used (working set plus page cache); after reclaim, ~1.2 GiB demoted DRAM to CXL; demotion rate spiked 12 to 1356 pages/s; node spill ratio tripled |
| `phaseC-recovery` | Workload deleted | DRAM back to 52% used; freed CXL pages released; demotion-rate series decays over its 5-minute window |
| `phaseD-rebalanced` | Tier-aware descheduler watching DRAM anonymous-memory utilization; pressure pushed the node past its threshold | The descheduler classified the node as overutilized at 85% DRAM anon, evicted the VM's launcher pod, and KubeVirt's eviction interceptor converted the eviction into a live migration (PreCopy) to the DRAM-healthy node; the VM stayed Running throughout |

The reclaim writes (`memory.reclaim` on a cgroup) are the lab's deterministic
dials for forcing demotion; in production the same movement happens through
ordinary memory pressure, and it is the descheduler — not a human — that
reacts to these metrics. Run on an emulated-CXL lab node: this validates
software behavior, not physical-device performance.
