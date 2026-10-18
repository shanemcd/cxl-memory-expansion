# Work log — CXL memory expansion

A dated record of work on this repository. The deliverables themselves live in
[docs/](docs/), [examples/](examples/), and [presentation/](presentation/).

## Session 1 — 2026-10-17 (evening)

**Context and framing.** This repository restarts the CXL memory work from a
deliberately simple premise, after an earlier exploration had grown heavy with
prototype mechanisms (custom QEMU memory-locking backends, libvirt and KubeVirt
patches for guest-scoped locking, capacity-budgeting fixtures). That exploration
answered useful questions — most importantly, that per-workload DRAM residency
enforcement is genuinely hard and does not belong in a first deliverable — but it
is not the product direction.

The product guidance for this minimum viable feature is:

1. Let CXL memory extend host RAM. The Linux kernel already tiers memory; no new
   placement API is needed for the default behavior.
2. Add metrics that make CXL memory usage visible.
3. Extend the descheduler so that tier pressure drives VM rebalancing.
4. Extend Prometheus recording rules on top of the new metrics.

Two standing rules shape everything: the hot working set of a node's VMs must
fit in DRAM with headroom (roughly 50–80% of DRAM at the high end), and for all
overcommit scenarios, operations must be driven mostly by observability, not by
per-workload requests.

**Research pass (web, this session).** Before writing anything, existing
mechanisms were surveyed so this work builds on them rather than reinventing:

- Linux memory-tier ABI, demotion/promotion counters, per-NUMA-node and
  per-cgroup accounting (kernel documentation and LWN).
- node_exporter collectors that already expose per-NUMA-node memory and
  vmstat counters (verified against upstream fixtures; exact metric names).
- KubeVirt's existing per-VM memory metrics and recording rules.
- The descheduler's utilization-based balancing: the merged upstream change
  that made it use real usage from metrics-server, and the published
  load-aware rebalancing pattern that classifies node pressure from
  Prometheus and live-migrates VMs off pressured nodes.
- Confirmation that no Kubernetes memory-tiering API exists upstream, and
  that DRA only mentions CXL as device motivation.

Findings and source URLs are recorded in
[docs/research-notes.md](docs/research-notes.md); the design documents cite them
where used.

**Artifacts this session.** Repository skeleton, this work log, and the
research notes. Design documents, example Prometheus rules, and the
presentation deck follow in subsequent entries below.

## Session 1 (continued) — 2026-10-18, implementation night

The scope was raised mid-session: the deliverable is a *working*
implementation, tested on the lab cluster, not just documentation. The
lab cluster has three nodes; the CXL node (worker-cxl-0) is emulated
(CPU-less NUMA node 1 of 4 GiB, kernel memory tiers 4 = DRAM and
22 = CXL). All work below is live on that cluster.

**memory-tier-exporter** (new repository,
`~/github/shanemcd/memory-tier-exporter`, local git only):

- Go exporter: tier mapping from `/sys/devices/virtual/memory_tiering`,
  per-NUMA-node memory from node meminfo, `pgdemote_*`/`pgpromote_*`
  from `/proc/vmstat`, PSI from `/proc/pressure/memory`, per-VM
  attribution from launcher-pod cgroup `memory.numa_stat` (discovered
  via the Kubernetes API). Unit-tested parsers against fixtures
  mirroring real kernel output.
- Deployed as a DaemonSet + Service + ServiceMonitor in a new
  `cxl-observability` namespace (labeled for platform-monitoring
  selection); image built and pushed to the internal registry. The
  platform Prometheus scrapes it on all three nodes.
- Discovered and fixed two issues from live behavior: the OpenShift
  managed node-exporter exposes *none* of the tier signals (meminfo_numa
  off, vmstat allow-listed without pgdemote, PSI off) — confirming the
  exporter is necessary; and anonymous THP is counted in `AnonHugePages`,
  not `AnonPages`, which under-reported working sets by 2.4 GiB on the
  demo node until fixed.

**Recording rules and alerts** (this repository, `examples/`):

- `node:memory_dram_used:ratio`, `node:memory_dram_anon:ratio`,
  `node:memory_cxl_used:ratio`, `node:memory_spilled:ratio`, movement
  rates, and per-VM rules; applied as PrometheusRule objects in the
  labeled namespace, validated live. All five alerts observed in
  pending/firing states (including a genuine DRAMNearFull on the compact
  lab master node).

**Demonstration run** (`demo-evidence/`, five phases):

- Baseline; bounded 150 MiB reclaim of the demo VM's cgroup (exactly
  150 MiB of cold guest pages demoted to CXL, VM Running, per-VM spill
  0.77); node pressure with a bounded 2 GiB global reclaim (~1.2 GiB
  demoted, demotion rate 12 to 1356 pages/s); recovery; and the
  descheduler phase below. A `memory-hog` utility (bounded allocation
  with a hot fraction) was added to the exporter repository to drive
  pressure repeatably.

**Tier-aware descheduler** (this repository, `examples/`):

- Upstream descheduler v0.37 already supports Prometheus-based node
  utilization in LowNodeUtilization: one query against the DRAM
  working-set recording rule makes rebalancing tier-aware with zero
  plugin code. Deployed as a Deployment with administrator thresholds
  (40/70), the evictor restricted to virt-launcher pods, VMs opting in
  via `evictionStrategy: LiveMigrate`.
- Found and fixed two upstream integration gaps: the Prometheus client
  sets TLS `ServerName` from `host:port` (no certificate matches; fix is
  `u.Hostname()`, one line — patch saved as
  `examples/descheduler-servername-fix.patch`, image built and pushed as
  `descheduler:v0.37.0-tlsfix`); and there is no configurable CA path
  (worked around by mounting a Secret with the service-account token and
  a combined CA bundle at the standard service-account path).
- End-to-end result: with the demo node pushed to 85% DRAM working-set
  utilization, the descheduler classified it overutilized, evicted the
  VM launcher pod, and KubeVirt's eviction-interceptor webhook converted
  the eviction into a PreCopy live migration to the DRAM-healthy node.
  The VM was Running throughout. (Two earlier attempts surfaced real
  configuration lessons: the evictor's local-storage protection must be
  disabled for launcher pods, and a VM pinned by nodeSelector cannot
  migrate — the demo VM was recreated unpinned.)

**Presentation.** A 17-slide deck with speaker notes was produced alongside
this work and is kept in the author's internal presentations collection,
not in this repository; the design documents, examples, and evidence here
are the community-facing record.

**Final verification (monitor-rerunnable):**

```sh
OC=/path/to/oc KUBECONFIG=/path/to/kubeconfig demo/verify.sh
```

The script takes its cluster specifics from the environment (`OC`,
`KUBECONFIG`, and, on hosts without direct DNS or trust for the monitoring
route, `THANOS_CACERT` / `THANOS_RESOLVE`); the lab values used for the
recorded run are intentionally not part of this repository.

Checks exporter unit tests, DaemonSet readiness, descheduler availability,
loaded PrometheusRules, and live series for every raw metric family and
recording rule through the monitoring API. Latest run: all checks passed
(2026-10-18 04:20 UTC).

**Lab state left running for inspection:** the exporter DaemonSet, the
recording rules and alerts, the tier-aware descheduler, and the demo VM
(now on the DRAM node, healthy). The pressure workload was removed.
Stale debugging grants (a service-proxy role in openshift-monitoring, a
temporary cluster-monitoring-view binding) were deleted.

**Deferred with reasons** (see `docs/scope-and-alternatives.md`): DRAM
residency enforcement, scheduler-level tier accounting, memory QoS
integration, guest-visible CXL, an operator/policy CRD, and proactive
demotion controllers.

## Session 2 — 2026-10-18 (continued), workload generalization

The exporter's per-VM attribution was renamed to per-workload attribution in
[shanemcd/memory-tier-exporter](https://github.com/shanemcd/memory-tier-exporter)
(commit `884d0ca`). The measurement core never depended on KubeVirt — only
discovery and naming did — so the exporter now exposes
`node_memory_tier_workload_*` series labeled `workload`, `workload_kind`,
`namespace` and `pod`, with pod discovery configurable via
`--pod-label-selector`, `--workload-name-label` and `--workload-kind`. The
KubeVirt preset remains the default (`kubevirt.io=virt-launcher` pods named
by `vmi.kubevirt.io/id`, `workload_kind="vmi"`), so the default `workload`
label still joins against `kubevirt_vmi_*` series.

This repository was updated in lockstep (no legacy series are emitted; the
exporter is pre-adoption): the recording rules
`vmi:memory_tier_resident_bytes:sum`, `vmi:memory_spilled:ratio` and
`vmi:memory_pgdemote:rate5m` became `workload:` rules aggregating by
`(node, workload, workload_kind, namespace)`, the
`MemoryTierVMHeavilySpilled` alert became
`MemoryTierWorkloadHeavilySpilled` keyed on `$labels.workload`, and the
design docs and demo capture tooling reference the new names. The
descheduler integration is unchanged: it consumes node-level rules
(`node:memory_dram_anon:ratio`), which were not renamed. Demo-evidence
snapshots in `demo-evidence/` were recorded before the rename and retain the
old series names as a historical record.
