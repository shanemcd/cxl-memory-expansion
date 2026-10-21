# Locked-memory teardown investigation — 2026-10-21

## Scope

The earlier locked-memory experiment left QEMU processes that did not exit after VM deletion or SIGKILL. No kernel stacks were captured then. This investigation captures the current failure state and runs isolated locked/unlocked controls before attributing that symptom to memory locking.

The worker runs `6.12.0-211.64.1.cxltest.el10.x86_64` with emulated CXL and demotion enabled. The test kernel includes `CONFIG_CXL_REGION_INVALIDATION_TEST=y`. Results do not establish behavior on a standard supported kernel or the VEP-383 implementation.

## Pre-existing failure, without locking

Two hugepage-backed demo VMs were already terminating before the investigation started. Their QEMU processes are PID 6990 (`demo-tier-dra`, 256 MiB hugetlb guest) and PID 6998 (`demo-dram-only`, 1 GiB hugetlb guest). Both command lines specify `mem-lock=off`; both report `VmLck: 0 kB`. An ordinary-memory VM, PID 6814 (`demo-tiered`), remains running.

The two terminating QEMUs remain in state R after another explicit SIGKILL. Their accumulated CPU times remain approximately 47 and 62 seconds. The node has about 12 GiB free and 15 GiB available, without a pressure workload. Their main-thread stacks are:

```text
task_work_run+0x61/0x90
syscall_exit_to_user_mode+0x17f/0x190
do_syscall_64+0x89/0x160
entry_SYSCALL_64_after_hwframe+0x76/0x7e
```

Two non-destructive SysRq `l` captures show associated vhost threads actively executing receive handling. PID 7002 (`vhost-6990`) and PID 7007 (`vhost-6998`) have accumulated approximately 17 and 16.6 hours of CPU time. Captured paths include `vhost_get_vq_desc`, `get_rx_bufs`, `vhost_get_avail_idx`, `vhost_enable_notify`, and `handle_rx`, through `vhost_run_work_kthread_list`.

This is evidence that the unkillable-QEMU symptom is **not specific to locked memory** in this lab. The vhost receive path is an investigation lead, not an established root cause. The captured `task_work_run` frame does not identify which callback is pending or prove which teardown dependency is blocked. Briefly taking only PID 6990's tap interface down did not release it; the interface was restored.

## CPU-quota intervention on the existing failure

Scheduler capture confirmed SIGKILL pending (`SigPnd` and `ShdPnd` include `0x100`) in both QEMU leaders. Each compute-container cgroup had `cpu.max = 10000 100000` (0.1 CPU), under a pod cgroup with `12000 100000` (0.12 CPU). The vhost threads belonged to those same container cgroups. The counters showed extensive throttling, with most CPU consumption charged as system time. These observations motivated a bounded quota intervention on the already-terminating workloads, not a change to the running VM specifications.

- **First workload:** temporarily writing `max 100000` to both pod and compute-container `cpu.max` immediately let PID 6990 become a zombie and then disappear. Its vhost thread disappeared at the same time. The other workload remained stuck throughout this comparison.
- **Second workload:** lifting only the pod quota left PID 6998 and its vhost thread unchanged across three one-second observations. Lifting the compute-container quota as well immediately let QEMU exit and the vhost thread disappear.

Both demo VMs subsequently restarted normally, without cycling the worker. The worker uptime was unchanged. Original quota values were restored where the old cgroup paths still existed; kubelet also reconciled the pod setting during the first intervention. The new VM specifications were not changed.

This establishes that CPU-quota changes released the **currently captured** failures. It does not explain why execution failed to make progress under the quota, prove the precise scheduler/vhost dependency, or establish that the historical locked-memory failure had the same cause. Removing a quota is a diagnostic/recovery intervention, not an implemented production fix. The exact intervention logs and before/after scheduler and signal snapshots are preserved below.

## Isolated direct-QEMU controls

A separate privileged diagnostic pod on the same worker uses the current virt-launcher image: QEMU `10.1.0-20.el9`. It does not replace KubeVirt components, enable the removed policy class, or change the running demo VMs. The pod has a 4 GiB container memory limit and an unlimited memlock rlimit.

| Test | Locking | Network | Termination | Result |
|---|---|---|---|---|
| Paused 1 GiB QEMU, no guest OS | off | none | SIGTERM | Exited |
| Paused 1 GiB QEMU, no guest OS | off | none | SIGKILL | Exited |
| Paused 1 GiB QEMU, no guest OS | on | none | SIGTERM | Exited |
| Paused 1 GiB QEMU, no guest OS | on | none | SIGKILL | Exited |
| Booted Fedora, 1 GiB guest | on | virtio-net with kernel vhost | SIGTERM | Exited |
| Booted Fedora, 1 GiB guest | on | virtio-net with kernel vhost | SIGKILL | Exited |
| Booted Fedora, 1 GiB guest | off | virtio-net with kernel vhost | SIGTERM | Exited |
| Booted Fedora, 1 GiB guest | on | virtio-net without kernel vhost | SIGTERM | Exited |

The paused locked runs report about 1,306,172 kB in `VmLck`. The booted locked/vhost run reports about 2,258,196 kB in `VmLck`, with about 1,412,088 kB RSS. `VmLck` is a locked virtual-memory measure, not an independent measurement of resident physical RAM or guest RAM.

Additional libvirt controls used version 11.10.0 with `<memoryBacking><locked/></memoryBacking>`, a 1 GiB guest, a qcow2 overlay, and a local vhost-backed virtio-net tap. The guest booted successfully; both `virsh destroy` and a separate ACPI shutdown completed. QEMU reported `VmLck: 2054676 kB` and an unlimited memlock rlimit in the recorded pre-destroy snapshot. Libvirt cgroup controllers were disabled by the launcher's existing configuration, so its domains remained within the diagnostic container's memory limit.

Finally, a fresh locked libvirt guest was left running while the diagnostic container and pod were assigned the same 0.1/0.12 CPU quotas as the affected workloads. Deleting that pod with a five-second grace period completed; the guest QEMU was absent at the next host inspection. This did **not** reproduce the quota-associated failure under the shorter, simpler lifecycle.

For the booted controls, a Fedora containerdisk backing image was copied from the existing launcher's read-only backing file and used with QEMU snapshot mode. The guest reached a Fedora login prompt. The tap was local to the diagnostic pod; it was not connected to the KubeVirt pod-network bridge or subjected to sustained traffic. Each guest ran for about 25 seconds before termination. The direct-QEMU controls do not reproduce libvirt-managed domain deletion; the additional libvirt and pod-deletion controls cover those lifecycle operations in a simplified sandbox. None reproduces the original KubeVirt network bridge and traffic history, long runtimes, migration, memory pressure, or the exact VEP-383 locking scope. They therefore narrow the hypothesis but do not close the investigation.

## Capture and reproduction artifacts

- `qemu-baseline-forensics-20261021.txt`: kernel/node state, exact QEMU command lines, thread stacks and syscalls, cgroup memory counters, cpusets, NUMA maps, and smaps rollups for the two stuck controls and healthy VM. NUL command-line separators were converted to spaces.
- `qemu-sysrq-cpu-backtraces-20261021.txt` and `qemu-second-sysrq-20261021.txt`: all-active-CPU kernel backtraces, with the second capture after explicit SIGKILL.
- `qemu-stuck-network-20261021.txt` and `qemu-tap-down-control-20261021.txt`: network namespace state and bounded tap-down observation.
- `qemu-locking-control-20261021.txt`: paused locked/unlocked termination matrix.
- `qemu-booted-*.txt`: booted guest controls, including serial-console output and termination result.
- `qemu-scheduler-signals-20261021.txt`: per-thread CPU runtime, pending signals, cgroup CPU quotas/throttling and freezer state before and after another successful SIGKILL call.
- `qemu-cpu-quota-intervention-20261021.txt` and `qemu-second-quota-intervention-20261021.txt`: controlled quota changes and immediate process-exit observations.
- `qemu-libvirt-*.txt`, `forensic-locked-domain.xml`, and `forensic-subreaper.go`: libvirt domain configuration and results. The small subreaper was needed because the sandbox's PID 1 was `sleep`, which did not reap orphaned capability-probe processes; the first standalone libvirt probe consequently stalled until a proper subreaper was used.
- `qemu-sandbox-quota-*.txt`: locked guest before diagnostic-pod deletion under matching CPU quotas, and its absence afterward.

Reusable scripts are under `demo/`: `capture-qemu-forensics.sh`, `qemu-locking-control.sh`, `qemu-booted-locking-control.sh`, and `qemu-locking-control-pod.yaml`. The pod manifest intentionally uses this lab's node and image references; adapt them before using it elsewhere. It is privileged diagnostic tooling, not a production deployment example.

## Historical build availability

Read-only registry inspection found stored manifests and referenced layers for the earlier KubeVirt build `v1.10.0-beta.0.37+4b696a92c03a92`. These were not deployed or fully pull-verified during this investigation. Immutable image references can be used for a later, more faithful reconstruction rather than relying on the mutable `mt` tag:

| Image in the internal registry's `kubevirt` namespace | Manifest digest |
|---|---|
| virt-launcher | `sha256:c58b857585ddebc9b47de58b46168da5c6a2d9710820cfa56a302f29a116b99d` |
| virt-handler | `sha256:599b9e6ab9bf1502a024daffe1ef592e015607f52ec60e124f945d143743dbc9` |
| virt-controller | `sha256:27c77a8e89aa3884096965ac4104fe597219fe5a7d14d1ff1654a1cb15bf710b` |

The historical and current launcher images share their substantial dependency/rootfs layers, including the QEMU/libvirt userspace used by the controls. The historical launcher alone is not a complete reconstruction: its converter, handler rlimit adjustment, controller headroom, API gating, and admission behavior have separate roles.

## Current conclusion

The previous attribution of the teardown hang to locking is unsupported. The same high-level failure was present with locking disabled, and lifting the compute-container CPU quota released both captured failures. New locked QEMU/libvirt controls, including pod deletion under a matching quota, exited successfully on the same kernel. CPU-bandwidth enforcement and vhost execution are now concrete investigation leads. The precise defect and its applicability to the historical locked-memory failure remain unresolved; no memory-reclaim or locked-page-unmapping explanation has been established by these captures.
