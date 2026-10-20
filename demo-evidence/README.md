# Demo evidence

Captured outputs from the memory-tiering demonstrations.

- `mlock-pressure-side-by-side.txt` — the mlock (gold-lock) retention
  experiment. Kept as the record of a **rejected alternative**: mlock
  retention held under 8 GB of node pressure, but the path was removed
  (per-VM accounting tax of ~1 GiB on top of guest RAM, plus an
  exit-path livelock when a locked QEMU is torn down — observed even
  with pod headroom and no pressure). Hugepages are the DRAMOnly
  backing; the pressure harness in `../demo/pressure-side-by-side.sh`
  demonstrates it the same way.
- `phase*.json` — the pre-policy tiering runs (demotion/recovery of
  plain workloads).
- `policy-*.md` — admission and tiering pressure demos for the
  MemoryPolicy classes.
