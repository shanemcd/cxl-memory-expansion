# Demo evidence

Captured outputs from the memory-tiering demonstrations.

- `mlock-pressure-side-by-side.txt` — the removed mlock (gold-lock) retention experiment. Retention held under 8 GB of node pressure. The implementation was removed following accounting problems and an unresolved teardown failure, but the extra launcher allowance was not an isolated measurement of locking's memory cost. Subsequent forensics found similar teardown symptoms with locking disabled; see below. Hugepages remain the deployed DRAMOnly backing.
- [`locking-forensics-20261021/`](locking-forensics-20261021/) — kernel stacks, signal/scheduler/cgroup captures, and locked/unlocked control runs. Two stuck non-mlocked QEMUs exited when their compute-container CPU quotas were lifted. New locked QEMU/libvirt controls exited normally. These results supersede the earlier locking-specific teardown attribution; the precise kernel defect remains unresolved.
- [`locking-restored-452d0b5a04/`](locking-restored-452d0b5a04/) — restored KubeVirt locking support, rollout verification, and a disposable locked VMI smoke test.
- [`locking-stress-20261021/`](locking-stress-20261021/) — paired locked/unlocked VM CPU, memory, network, and teardown tests at 1 CPU and 100m, including bounded DRAM pressure. All three pairs exited; no hang was reproduced in these short runs. Includes rerun instructions and QEMU/vhost captures.
- `phase*.json` — the pre-policy tiering runs (demotion/recovery of
  plain workloads).
- `policy-*.md` — admission and tiering pressure demos for the
  MemoryPolicy classes.
