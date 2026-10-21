# Demo evidence

Captured outputs from the memory-tiering demonstrations.

- `mlock-pressure-side-by-side.txt` — the removed mlock (gold-lock) retention experiment. Retention held under 8 GB of node pressure. The implementation was removed following accounting problems and an unresolved teardown failure, but the extra launcher allowance was not an isolated measurement of locking's memory cost. Subsequent forensics found similar teardown symptoms with locking disabled; see below. Hugepages remain the deployed DRAMOnly backing.
- [`locking-forensics-20261021/`](locking-forensics-20261021/) — kernel stacks, signal/scheduler/cgroup captures, and locked/unlocked control runs. Two stuck non-mlocked QEMUs exited when their compute-container CPU quotas were lifted. New locked QEMU/libvirt controls exited normally. These results supersede the earlier locking-specific teardown attribution; the precise kernel defect remains unresolved.
- `phase*.json` — the pre-policy tiering runs (demotion/recovery of
  plain workloads).
- `policy-*.md` — admission and tiering pressure demos for the
  MemoryPolicy classes.
