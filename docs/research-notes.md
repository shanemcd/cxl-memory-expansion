# Research notes: existing mechanisms this design builds on

These notes record verified facts about existing Linux, Kubernetes, and
virtualization-platform mechanisms, with upstream sources. They exist so the
design documents can cite established behavior rather than assert it. Each fact
is marked **verified** (checked against upstream source or fixtures this
session) or **documented** (stated by the cited upstream documentation, not
independently re-derived here).

## 1. Linux memory tiering

### CXL memory appears as ordinary NUMA memory

**Documented.** A CXL memory expander configured as system RAM is onboarded by
the kernel as ordinary memory, typically on a NUMA node without CPUs. The
kernel assigns each NUMA node to a *memory tier* using an *abstract distance*
derived from platform firmware information (HMAT for host-managed memory, CDAT
for CXL device memory). Smaller abstract distance means a faster tier.

- Tier membership is visible in sysfs:
  `/sys/devices/virtual/memory_tiering/memory_tierN/nodelist` lists the NUMA
  nodes in tier `N`, where a smaller `N` is a faster tier.
  Source: [kernel ABI documentation, sysfs-kernel-mm-memory-tiers](https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-kernel-mm-memory-tiers)
- The demotion machinery and its rationale: [LWN.net, "mm/demotion: Memory tiers and demotion"](https://lwn.net/Articles/897536/), covering the merged
  memory-tier and demotion patch series including the
  `Documentation/admin-guide/mm/memory-tiering.rst` admin guide it added.
- Practical monitoring walkthroughs of demotion and promotion counters:
  [kernel-internals.org, CXL Memory Tiering](https://kernel-internals.org/mm/cxl-memory-tiering)
  and [Steve Scargall, Using Linux Kernel Memory Tiering](https://stevescargall.com/blog/2022/06/using-linux-kernel-memory-tiering/).

### Demotion and promotion are reclaim-driven

**Documented.** When memory pressure triggers reclaim, the kernel can *demote*
cold pages from a faster tier to a slower tier (DRAM to CXL, or CXL to swap)
instead of discarding or swapping them outright, and *promote* hot pages back
toward faster tiers. Movement is decided by the kernel's own aging (LRU, and
MGLRU where enabled) — there is no userspace page mover in the mainline path.

**Verified.** The counters `pgdemote_kswapd`, `pgdemote_direct`, and the
`pgpromote_*` family are plain `/proc/vmstat` fields (kernel
`mm/vmstat.c`, `mm/memcontrol.c`), so any vmstat-based exporter picks them up
without new kernel work.

- `numa_demotion_enabled` controls demotion and defaults off in some
  distributions (RHEL ships it disabled); it must be enabled per node.
  Source: kernel admin guide referenced above; distribution defaults differ.

### Allocation policy is not residency policy

**Documented.** This is the most important negative result for anyone
designing tier controls:

- `cpuset.mems` restricts which NUMA nodes a cgroup's tasks may *allocate*
  from. It is not a fence against *later movement*: reclaim-driven demotion
  historically ignored cpuset masks entirely; newer kernels attempt to respect
  `mems_allowed`, but pages shared with — or originally charged to — another
  cgroup can still be demoted outside a consumer's intended nodes.
- The cgroup v2 documentation also warns that changing `cpuset.mems` on a
  populated cgroup migrates existing pages only best-effort.

Sources: [eunomia.dev, "Can a Container Keep Its Memory Out of CXL?"](https://eunomia.dev/research/cxl-memory-tier-isolation)
(which quotes the kernel CXL reclaim documentation and cgroup v2
documentation on these points), plus the upstream cgroup-v2 documentation
itself.

Consequence: a hard "this workload's memory may never reside on CXL" contract
cannot be built from mainline cpuset alone; it needs locking or hugepage
mechanisms. That is precisely why this repository's MVP chooses observability
over enforcement.

### Per-node and per-cgroup accounting already exist

**Documented.**

- Per NUMA node: `/sys/devices/system/node/nodeN/meminfo` (MemTotal, MemFree,
  MemUsed, Active, Inactive, anon/file breakdowns, …) and
  `/sys/devices/system/node/nodeN/numastat` (numa_hit, numa_miss, local_node,
  other_node, …).
- Per cgroup: cgroup v2 `memory.numa_stat` reports a cgroup's memory broken
  down by NUMA node, with anon/file breakdowns on recent kernels.

## 2. Prometheus node_exporter

**Verified against upstream fixtures** (`collector/fixtures/e2e-output.txt` in
[prometheus/node_exporter](https://github.com/prometheus/node_exporter)):

- The `meminfo_numa` collector exposes per-NUMA-node memory from
  `/sys/devices/system/node/node[0-9]*/meminfo` and `numastat` as
  `node_memory_numa_<Field>{node="N"}` — e.g.
  `node_memory_numa_MemTotal{node="0"}`, `node_memory_numa_MemUsed`,
  `node_memory_numa_MemFree`, `node_memory_numa_Active_anon`, and numastat
  counters such as `node_memory_numa_local_node_total`. **This collector is
  disabled by default** (`--collector.meminfo-numa`).
- The `vmstat` collector exposes `/proc/vmstat` verbatim as `node_vmstat_*`,
  which includes `node_vmstat_pgdemote_kswapd`,
  `node_vmstat_pgdemote_direct`, and `node_vmstat_pgpromote_*` once the kernel
  provides them.
- Pressure stall information is exposed as `node_pressure_memory_*` (some
  uptime required on cgroup v2 hosts; the PSI interface is per-cgroup and
  system-wide).

**Verified live on an OpenShift cluster (this changed the design):** the
platform-managed node-exporter runs with `meminfo_numa` **off**, the vmstat
collector **allow-listed to a handful of fields that exclude `pgdemote_*`**,
and the `psi` collector off — so none of the tier-relevant signals reach the
platform's Prometheus even though the node_exporter upstream *could* expose
two of them. Widenning those defaults upstream is the right long-term fix;
until then a dedicated exporter is required.

**Gaps (nothing upstream exports these today):**

- The node-to-tier mapping (which NUMA nodes are CXL / slower tiers, per
  abstract distance) is not exported by node_exporter.
- Per-pod or per-VM `memory.numa_stat` is not exported by node_exporter's
  cgroup collectors.
- **Per-node meminfo counts anonymous transparent hugepages in
  `AnonHugePages`, not `AnonPages`** — and virtualization guests allocate
  their memory predominantly as THP. An anonymous-memory metric that omits
  `AnonHugePages` under-reports exactly the memory that matters for
  working-set signals (discovered during validation: a node measured at 45%
  anon was truly at 86% once THP was included).

## 3. KubeVirt VM memory observability

**Documented.** KubeVirt already publishes per-VM-instance memory metrics and
recording rules
([kubevirt/docs/observability/metrics.md](https://github.com/kubevirt/kubevirt/blob/main/docs/observability/metrics.md)):

- Gauges: `kubevirt_vmi_memory_resident_bytes` (resident set of the process
  running the domain), `kubevirt_vmi_memory_available_bytes`,
  `kubevirt_vmi_memory_usable_bytes`, `kubevirt_vmi_memory_unused_bytes`,
  `kubevirt_vmi_memory_cached_bytes`, `kubevirt_vmi_memory_domain_bytes`,
  `kubevirt_vmi_memory_actual_balloon_bytes`, and guest-side swap traffic
  (`kubevirt_vmi_memory_swap_in_traffic_bytes` /
  `kubevirt_vmi_memory_swap_out_traffic_bytes`).
- Fault counters: `kubevirt_vmi_memory_pgmajfault_total`,
  `kubevirt_vmi_memory_pgminfault_total`.
- `kubevirt_vmi_launcher_memory_overhead_bytes` for the launcher overhead.
- Recording rules exist, e.g.
  `container:kubevirt_memory_delta_from_requested_bytes:max`.

**Gap:** none of these attributes memory to a NUMA node or memory tier. A VM's
guest memory location (DRAM vs CXL) is invisible in the current metric set.

## 4. Descheduler: utilization-driven rebalancing

**Documented.**

- Upstream descheduler `LowNodeUtilization` / `HighNodeUtilization`
  traditionally compute node utilization from pod **requests**, not live usage,
  matching the scheduler's model
  ([kubernetes-sigs/descheduler](https://github.com/kubernetes-sigs/descheduler)).
- Merged upstream change
  [PR #1555, "Use actual node resource utilization by consuming kubernetes metrics"](https://github.com/kubernetes-sigs/descheduler/pull/1555):
  `LowNodeUtilization` gained `metricsUtilization.metricsServer: true` to
  classify nodes by actual usage obtained from metrics-server.
- The descheduler main branch carries a Prometheus client integration
  (`pkg/descheduler/prom_client_controller.go`), i.e. consuming Prometheus
  time series from a descheduler profile is an established extension point.
- Published load-aware rebalancing pattern for virtualization
  ([Red Hat Developer, "Load aware rebalancing with OpenShift Virtualization"](https://developers.redhat.com/blog/2024/12/19/load-aware-rebalancing-openshift-virtualization),
  Dec 2024): the descheduler gathers per-node PSI (pressure stall information)
  from Prometheus, classifies nodes as over/under/appropriately utilized,
  evicts VMs (triggering live migration), and taints overutilized nodes with
  `PreferNoSchedule` so the scheduler steers new placements away from them.
  The article explicitly notes this taint-based approach was chosen over a
  Trimaran-style scheduler plugin to avoid making the scheduler depend on the
  observability stack.

**Gap:** all of the above treat "memory" as a single number. When CXL extends
RAM, node memory utilization merges DRAM and CXL usage, so DRAM pressure — the
quantity that actually predicts performance loss and spillover — is invisible
without tier-aware metrics and thresholds.

## 5. Kubernetes: what exists and what does not

**Documented.**

- Kubernetes reports a node's ordinary memory as one `memory` resource. When
  CXL memory onboards as system RAM, the node's capacity — and every pod's
  `memory` request — silently includes DRAM plus CXL. There is no per-tier
  resource accounting, and no memory-tiering KEP exists in
  kubernetes/enhancements as of this writing.
- Dynamic Resource Allocation (DRA, KEP 3063) mentions CXL in its motivation,
  but DRA is device-centric and workload-request-centric: each pod must claim
  resources. That model fits accelerators, not transparent system RAM.
- Node-swap support (KEP 2400) is the precedent for a node-level memory
  posture being configured through kubelet/administrator action rather than
  per-workload API.
- NUMA-affinity scheduling exists today (NodeResourceTopology objects, the
  NUMA Resources Operator, the scheduler-plugins NodeResourceTopology plugin,
  and the kubelet Memory Manager's Static policy). These solve placement
  *locality*, not tier *class* or tier *utilization*; the MVP in this
  repository does not require them.

## 6. Live validation notes (2026-10-18, emulated-CXL cluster)

**Documented here because they are facts about software behavior, portable
beyond this cluster.** On a three-node cluster whose CXL node is emulated
(CPU-less NUMA node, kernel tiers 4 = DRAM and 22 = CXL):

- Bounded `memory.reclaim` on a VM launcher pod's cgroup demoted exactly the
  requested amount of cold guest memory to the CXL node (150 MiB requested,
  ~150 MiB moved), hot pages stayed on DRAM, the VM stayed Running.
- A global 2 GiB reclaim under node pressure demoted ~1.2 GiB of cold pages
  DRAM to CXL; the demotion-rate recording rule captured the spike
  (12 to 1356 pages/s).
- The kernel reached a "full but healthy" equilibrium by dropping page cache
  rather than demoting anonymous pages: per-node `MemUsed` (which includes
  reclaimable cache) overstated pressure, and the anonymous-memory ratio
  (THP included) was the honest working-set signal.
- Upstream descheduler v0.37's Prometheus-backed `LowNodeUtilization`
  classified nodes by that DRAM working-set ratio and evicted a VM launcher
  pod from an over-threshold node; KubeVirt's eviction-interceptor webhook
  converted the eviction into a PreCopy live migration to a healthy node,
  with the VM Running throughout.
- Two upstream integration gaps found: the descheduler's Prometheus client
  sets TLS `ServerName` from `host:port` (no cert matches; one-line fix),
  and it offers no configurable CA path (worked around with a Secret-mounted
  credential bundle).

## 7. The performance gradient (planning context, not a claim)

**Planning context.** Orders of magnitude commonly used for planning: local
DRAM tens of nanoseconds; CXL-attached memory on the order of 100–200 ns added
latency (comparable to cross-socket NUMA remote memory); swap on the order of
milliseconds. CXL device performance varies by implementation (expander cards
populated with conventional DRAM modules differ from other devices), which is
why firmware-reported characteristics (HMAT/CDAT) and measured application
impact, not the CXL label alone, must drive workload decisions. This
repository makes no physical-CXL performance claims; emulated CXL can validate
software behavior only.
