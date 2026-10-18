# Observability design for memory tiers

This document specifies what must be visible to operate CXL-extended hosts
safely, where each signal comes from, and what is derived. It reflects a
working implementation: the
[memory-tier-exporter](https://github.com/shanemcd/memory-tier-exporter)
collects the node-level signals, and the recording rules and alerts in
[examples](../examples/) are deployed and validated on a lab cluster.

## What an operator needs to see

Operating an overcommitted, CXL-extended fleet on observability (see
[problem and principles](problem-and-principles.md)) means answering five
questions continuously, per node:

1. **How full is each tier?** (DRAM utilization, slower-tier utilization)
2. **How much of the node's memory is working set versus reclaimable
   cache?** (anonymous memory is the working set; page cache is not)
3. **Is memory moving between tiers, and how fast?** (demotion and
   promotion rates; sustained high rates mean churn)
4. **Where does each VM's memory actually live?** (per-VM tier attribution)
5. **Is anything stalling?** (memory pressure)

Question 5 has a dedicated kernel mechanism — pressure stall information
(PSI) — and question 4 needs per-VM accounting. The others come from
per-NUMA-node memory statistics that the kernel has always kept, but that
common node collectors do not expose with default settings.

## Why a new exporter

The standard Prometheus node collector (node_exporter) can expose most of
this, but not by default, and fleet-managed deployments pin its collector
set:

- per-NUMA-node memory requires the `meminfo_numa` collector — **disabled by
  default**, and not enabled in OpenShift's managed node-exporter;
- demotion/promotion counters live in `/proc/vmstat` (`pgdemote_*`,
  `pgpromote_*`) — the vmstat collector **allow-lists a small field set**
  that excludes them;
- PSI requires the `psi` collector — disabled by default;
- the node-to-tier mapping (`/sys/devices/virtual/memory_tiering/...`) is
  not exported by anything;
- per-VM attribution requires reading each VM launcher pod's cgroup
  `memory.numa_stat` — not a node_exporter concern at all.

The memory-tier-exporter closes all of these in one small DaemonSet, with
its own `node_memory_tier_` metric prefix so nothing double-counts against
node_exporter, and a `node` label carrying the Kubernetes node name as the
join key with platform metrics.

## Metric inventory

All metrics below are implemented and verified on a live cluster, except
where noted. "Rank 0" is the fastest tier present on a node (CPU-attached
DRAM on current platforms); `tier` is the kernel's own memory-tier number
derived from abstract distance (smaller is faster — e.g. DRAM presented as
tier 4 and CXL as tier 22 on the validation node).

### Tier identity and capacity

| Metric | Labels | Source |
|---|---|---|
| `node_memory_tier_nodes` | node, numa_node, tier, rank | sysfs memory_tiering nodelist |
| `node_memory_tier_memtotal_bytes` / `memfree_bytes` / `memused_bytes` | node, numa_node, tier, rank | per-node meminfo |
| `node_memory_tier_anon_bytes` | node, numa_node, tier, rank | per-node meminfo AnonPages **+ AnonHugePages** |
| `node_memory_tier_anon_thp_bytes` | node, numa_node, tier, rank | per-node meminfo AnonHugePages |
| `node_memory_tier_file_bytes` | node, numa_node, tier, rank | per-node meminfo FilePages |

The anon aggregation matters and was learned the hard way: anonymous
transparent hugepages are counted in `AnonHugePages`, not `AnonPages`, and
virtualization guests allocate their memory predominantly as THP. A metric
that omits THP under-reports exactly the memory that matters. `memused`
additionally includes reclaimable page cache, which is why the recording
rules keep `used` and `anon` ratios separate.

### Movement

| Metric | Labels | Source |
|---|---|---|
| `node_memory_tier_pgdemote_total` | node, mode (kswapd / direct / khugepaged) | /proc/vmstat |
| `node_memory_tier_pgpromote_total` | node, mode (success / candidate / ...) | /proc/vmstat |

### Pressure

| Metric | Labels | Source |
|---|---|---|
| `node_memory_tier_psi_stalled_seconds_total` | node, scope (some / full) | /proc/pressure/memory |
| `node_memory_tier_psi_stalled_ratio` | node, scope, window (10 / 60 / 300) | /proc/pressure/memory |

PSI is absent on some kernels (including the validation lab's CXL test
kernel): the exporter simply emits nothing rather than zeros, and the
absence is visible as missing series — unknown, not zero.

### Per-VM attribution

| Metric | Labels | Source |
|---|---|---|
| `node_memory_tier_vm_anon_bytes` / `vm_file_bytes` / `vm_shmem_bytes` | node, vmi, namespace, numa_node, tier, rank | launcher pod cgroup `memory.numa_stat` |
| `node_memory_tier_vm_pgdemote_total` / `vm_pgpromote_total` | node, vmi, namespace, mode, numa_node, tier, rank | same, movement rows |

The exporter discovers launcher pods through the Kubernetes API (label
`kubevirt.io=virt-launcher`, VMI name from `vmi.kubevirt.io/id`) and reads
each pod's cgroup. These numbers include the launcher's own overhead (QEMU,
libvirt, sidecars) — attribution, not a precise guest-RAM guarantee.

## Recording rules

Defined in [examples/recording-rules.yaml](../examples/recording-rules.yaml),
validated live. Naming follows the `<level>:<name>:<operation>` convention
used by the platform's virtualization rules.

| Rule | Purpose |
|---|---|
| `node:memory_dram_used:ratio` | headline DRAM utilization (includes page cache) |
| `node:memory_dram_anon:ratio` | working-set DRAM utilization — the sizing-rule signal and the descheduler input |
| `node:memory_cxl_used:ratio` | slower-tier utilization (absent on nodes without a slower tier, by design) |
| `node:memory_spilled:ratio` | share of used memory residing below DRAM |
| `node:memory_pgdemote:rate5m` / `pgpromote:rate5m` | movement rates |
| `vmi:memory_tier_resident_bytes:sum` | per-VM resident memory by tier |
| `vmi:memory_spilled:ratio` | per-VM spill fraction |
| `vmi:memory_pgdemote:rate5m` | per-VM demotion rate |

## Alerts

Defined in [examples/alerts.yaml](../examples/alerts.yaml). All five were
observed reaching `pending` or `firing` states during validation:

- `MemoryTierDRAMNearFull` (warning) — DRAM > 90% for 15 minutes: the hot
  set is pressing the planning ceiling.
- `MemoryTierSpillSustained` (info) — > 20% of used memory below DRAM for
  30 minutes: expected under overcommit, worth eyeballing.
- `MemoryTierDemoteChurn` (warning) — sustained demotion > 1000 pages/s:
  the node is cycling memory between tiers.
- `MemoryTierVMHeavilySpilled` (info) — a VM with > 50% of its memory below
  DRAM for 30 minutes: the natural descheduler eviction candidate.
- `MemoryTierExporterDown` (warning) — the observability itself.

Thresholds are starting points; the point of the rules is that operators tune
them against measured behavior instead of guessing.

## Deployment shape (OpenShift)

- DaemonSet with read-only host mounts for `/sys`, `/proc`, and the cgroup
  filesystem; a service account with pod-list rights for VM attribution.
- Service + ServiceMonitor in a namespace labeled for platform-monitoring
  selection, so the platform Prometheus scrapes it with no extra
  infrastructure.
- PrometheusRule objects in the same labeled namespace for the recording
  rules and alerts.
- On clusters using node_exporter's textfile collector instead, the
  exporter also runs standalone (HTTP) or with VM attribution disabled.

## Known gaps

- **Per-VM attribution granularity**: launcher overhead is included; a
  cleaner split would read QEMU's own memory maps. Sufficient for
  rebalancing decisions, insufficient for billing-grade accounting.
- **File-cache spill**: spilled ratio counts anonymous and file pages on
  slower tiers; file cache on CXL is mostly harmless and may inflate the
  perceived spill on read-heavy nodes. A future refinement splits it.
- **PSI availability** varies by kernel; treat absence as unknown.
- **Tier semantics across heterogeneous fleets**: rank is per-node; a rank-1
  tier on one host (CXL expander DRAM) may differ in latency from another
  (different device class). Abstract distance is exported as the `tier`
  label precisely so fleet-wide queries can group by actual device class
  rather than by rank alone.
