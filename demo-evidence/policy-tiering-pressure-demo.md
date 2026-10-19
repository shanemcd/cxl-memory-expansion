# MemoryPolicy tiering pressure demo (2026-10-18)

Live-cluster evidence for the stock-components policy stack: two governed
VMs under a node memory-pressure event on `worker-cxl-0`
(node0 = 8 GiB DRAM + 2 GiB pinned 2 Mi-hugepage pool, node1 = 4 GiB
emulated CXL, kernel memory tiering: tier 4 = node0, tier 22 = node1).
Emulated CXL — this validates software behavior, not device performance.

Operator `memory-tier-operator:v10` (branch `memory-policy-classes`),
webhook governance in namespace `cxl-observability`
(labeled `memorytiering.shanemcd.com/governed=true`).

## Setup

| Workload | Class | Backing | Guest mem | Scheduling |
|---|---|---|---|---|
| `demo-gold-hp` (VMI) | `gold-hp` → DRAMOnly+Hugepages | hugepages-2Mi 512Mi + Guaranteed shape (webhook-rendered) | 512Mi | worker-cxl-0 (MM Static, node-0-only pool) |
| `demo-tiered` (VMI) | `tiered` → Tiered | plain (kernel demotion is the mechanism) | 448Mi | worker-cxl-0 |
| `memory-hog` (pod) | none (ungoverned, BestEffort) | plain | — | worker-cxl-0 |

Both VMs ran a cloud-init bootcmd writing cold data
(`dd if=/dev/urandom of=/dev/shm/cold.bin`) so each VM carries cold
anonymous memory a host-side demotion pass can move.

The pressure event: `memory-hog` grows stepwise (5.0 GiB → 8.0 GiB total,
touching 1 s apart; final profile `--total-mb=8000 --hot-mb=7900`) while
keeping almost all of its pages hot, forcing node0 reclaim below its
watermarks with an inactive-list nearly empty of hog pages.

## Pressure escalation (node0)

| hog total | node0 MemFree | pgdemote_kswapd (cum.) | note |
|---|---|---|---|
| 5.0 GiB | 133 MiB | ~75.6 k pages | first demotions begin (hog cold tail) |
| 5.25 GiB | 193 MiB | ~75.6 k | settles above high watermark; kswapd sleeps |
| 5.9 GiB | 225 MiB | ~227.6 k | ~437 MiB demoted this round |
| 6.55 GiB | 137 MiB | ~295.0 k | hog spills 505 MiB to node1 |
| 8.0 GiB | 155 MiB | ~645.5 k | ~2.5 GiB total demoted; deep pass ages VM anon |

Node0 zone watermarks (Normal): min 13996 / low 17495 / high 20994 pages
(≈ 55/68/82 MiB). Free above `high` = kswapd sleeps, no demotion — the
demo requires pressure that actually crosses watermarks.

## Result: per-workload attribution (exporter, one scrape)

```
node_memory_tier_workload_anon_bytes{workload="demo-gold-hp",numa_node="0",tier="4"} 5.5263232e+07
node_memory_tier_workload_anon_bytes{workload="demo-gold-hp",numa_node="1",tier="22"} 3.5766272e+07
node_memory_tier_workload_anon_bytes{workload="demo-tiered", numa_node="0",tier="4"} 5.59771648e+08
node_memory_tier_workload_anon_bytes{workload="demo-tiered", numa_node="1",tier="22"} 3.0081024e+07
node_memory_tier_workload_anon_bytes{workload="memory-hog",  numa_node="0",tier="4"} 7.767269376e+09
node_memory_tier_workload_anon_bytes{workload="memory-hog",  numa_node="1",tier="22"} 6.35543552e+08
```

Recorded-rule view (Thanos query API, `workload:memory_spilled:ratio`):

| workload | spill ratio | interpretation |
|---|---|---|
| `demo-gold-hp` | 0.380 | launcher-pod **overhead** anon spilled; guest memory is hugepage-backed (see below) |
| `demo-tiered` | 0.082 | coldest guest pages demoted to CXL — Tiered class doing its job |
| `memory-hog` | 0.076 | unmanaged BestEffort workload also spills (636 MiB) |
| infra daemonsets | 0.29–0.99 | node-wide pressure spills everything's cold pages |

## Hugepage pinning (the DRAMOnly guarantee)

```
$ grep -i hugepages_total /sys/devices/system/node/node{0,1}/meminfo
Node 0 HugePages_Total:  1024   (2 GiB pool, 768 free = 512 MiB in use by demo-gold-hp's guest)
Node 1 HugePages_Total:     0   (the pool exists only on the DRAM node)
```

`demo-gold-hp`'s 512 MiB guest memory is backed by node-0 hugepages, which
cannot be demoted (node1 has no hugepage pool at all). The 0.380 spill
ratio above is the launcher pod's ~91 MiB of ordinary anon (QEMU/device
overhead), not guest memory — hugepages don't appear in the anon
counters at all.

## Alerts (Thanos /api/v1/alerts)

```
MemoryTierDRAMOnlyWorkloadSpilled | pending | demo-gold-hp cxl-observability
MemoryTierDRAMNearFull            | pending | (node-level, worker DRAM)
MemoryTierDemoteChurn             | pending | (demotion rate elevated)
MemoryTierSpillSustained          | pending | (node-wide spill sustained)
MemoryTierWorkloadHeavilySpilled  | pending | x15 infra daemonsets (>50% spilled)
```

`MemoryTierDRAMOnlyWorkloadSpilled` matched only `demo-gold-hp` — the
kube-state-metrics join (`label_memorytiering_shanemcd_com_policy_mode="DRAMOnly"`
+ `label_vmi_kubevirt_io_id` → `workload`) selects exactly the DRAMOnly
workload, and it fires on its nonzero spill.

## Honest findings

1. **The DRAMOnly guest-memory guarantee is structural and held**: guest
   memory is hugepage-backed from a node-0-only pool; node1 cannot host
   those pages. No spill of guest memory was observed at any pressure.
2. **The guarantee is pod-scoped, not guest-scoped**: the launcher pod's
   ordinary anon (QEMU, device buffers, ~90 MiB) demotes like any other
   workload. The spill alert firing on a DRAMOnly VM means "contract
   drift at the pod level", and that is exactly the verify-after-fact
   signal the design intends — but operators should read it as overhead
   spill unless hugepages are absent.
3. **Demotion victim selection is LRU-age-based**: an idle-but-active
   guest's anonymous pages age slowly. The tiered VM only spilled after
   the deepest pass (8 GiB hog); its 560 MiB active set stayed on DRAM
   throughout. "Tiered VM spilled 8%" understates the asymmetry the
   kernel actually enforces: hot pages stay, cold pages move.
4. **Node-wide pressure is indiscriminate**: every daemonset's cold pages
   spilled (several >50%), which is expected kernel behavior and is what
   the node-level alerts (DRAMNearFull, SpillSustained, DemoteChurn) are
   for. Per-workload policy signals are the differentiated ones.

## Recovery (pressure relieved, workload replaced)

Deleting the hog returned node0 free to 7.7 GiB. Cold demoted pages do
**not** auto-promote — `pgpromote_success` stayed 0 — because nothing
faulted them back (promotion is access-driven). The DRAMOnly workload
was instead *replaced*: deleting and recreating the VMI re-established
fresh DRAM-only placement, and the alert resolved:

```
workload:memory_spilled:ratio                 # fresh VMs, all workloads
 demo-gold-hp 0   demo-tiered 0   (every other workload 0 as well)

MemoryTierDRAMOnlyWorkloadSpilled              # resolved (left active set)
```

## Incident: unkillable launcher during VMI deletion (kernel livelock)

Deleting `demo-gold-hp` at 20:57 wedged: kubelet/cri-o could not stop
the launcher containers (`StopContainer ... DeadlineExceeded` repeating
every ~2 min for 3 h), the VMI sat `Terminating`, and the guest kept
running. `sysrq-t` showed every thread of the container's processes
parked in the same kernel path, state R at 0% CPU — signal delivery
could never complete, so even SIGKILL was undeliverable:

```
task:virt-launcher-m state:R  running task  pid:6866
 __schedule+0x2a5/0x630
 __cond_resched+0x3c/0x60
 task_work_run+0x61/0x90
 get_signal+0x89/0x870
 arch_do_signal_or_restart+0x35/0x100
 syscall_exit_to_user_mode+0x117/0x190
```

cri-o's own log corroborated: "Detected process (6866) in state R blocked
for more than 11051 seconds ... One of the child processes might be in
uninterruptible sleep." The trigger window is the kill signal arriving
immediately after ~2.5 GiB of demotion churn on the
6.12.0-211.64.1.cxltest.el10 test kernel — recorded as an honest finding
against the emulated-CXL test kernel, not against the stock software
stack under test.

Recovery: node reboot. (The guest's first ACPI reset hung before the
serial console came up; issuing `system_reset` over the QEMU monitor
restarted the boot.) After the node returned Ready, the boot-pinned
MachineConfig units (`memorytier-hugepages-node0.service`,
`cxl-region-commit.service`) re-provisioned the node-0 hugepage pool
automatically, both VMIs were recreated, and the governance +
attribution chain came back healthy with zero manual node configuration.
