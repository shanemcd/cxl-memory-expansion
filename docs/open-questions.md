# Open questions

Honest unknowns, ordered roughly by how much they gate real deployments.
None of them invalidate the MVP's shape; all of them deserve answers before
any density claims are made beyond the software-behavior level.

## Physical CXL performance and economics

Everything here was validated on emulated CXL (a CPU-less NUMA node backed
by host DRAM), which proves the software path — tiering onboards, demotion
moves pages, metrics see it, rebalancing reacts — and nothing about device
performance. On physical hardware:

- What is the real added latency and sustained bandwidth of the candidate
  devices (expander cards populated with DRAM modules differ from other
  device classes), and how does VM workload latency degrade as spill grows?
- Firmware-reported characteristics (HMAT/CDAT) — do they match measured
  behavior, and are they the right grouping key for fleet queries?
- What is the price-performance crossover where CXL capacity beats DRAM
  density, per workload class?

Until these are measured on physical devices, all capacity examples are
illustrative and no application-level service-level claims are made.

## Sizing the DRAM ceiling

The 50–80% planning ceiling is guidance, not a measured constant. Open:

- What fraction do representative workloads actually need, measured by the
  `dram_anon` ratio at which latency-sensitive behavior degrades?
- How should the ceiling account for migration traffic (a migrating VM
  doubles its working set across source and target)?
- Should the ceiling be per workload class, per node, or fleet policy —
  and who tunes it (this repo's answer: the cluster administrator, against
  metrics)?

## Demotion behavior under real fleets

- Does kernel aging (MGLRU on and off) keep genuinely hot pages in DRAM
  across mixed VM fleets, or are there access-pattern classes that fool
  the aging and thrash?
- The validation kernel exposes no `numa_demotion_enabled` knob (demotion
  is unconditional); distribution defaults vary. What is the supported
  enablement path per OS release?
- Sustained demotion-promotion churn was alertable but not deeply studied:
  what rate corresponds to user-visible degradation?

## Per-VM attribution precision

Current attribution includes launcher overhead (QEMU, libvirt, sidecars) in
the VM's numbers. For rebalancing decisions this is fine; for tighter
questions ("is the *guest's* hot set on DRAM?") a QEMU-memory-map-aware
split would be needed. Also untested: attributing shared file pages that
multiple VMs map.

## Descheduler integration depth

- Taint pressured nodes (`PreferNoSchedule`) so the scheduler does not
  refill what the descheduler just drained — the published refinement,
  straightforward on the same mechanisms, not yet in the validated profile.
- Prefer the most-spilled VM as the eviction candidate (the per-VM spill
  metrics exist; the plugin currently uses default ordering).
- Headroom-aware placement of migration targets: the scheduler places by
  summed memory, which is correct for capacity but not for DRAM pressure —
  a node can receive a migration that keeps it over the DRAM ceiling. The
  reaction loop eventually moves it again; an admission refinement would
  short-circuit the oscillation.

## Platform integration

- Upstreaming: the TLS ServerName fix (tiny), a configurable Prometheus CA
  path (small), and eventually the tier metrics themselves — the natural
  home for per-NUMA and tier metrics is the standard node exporter, where
  the `meminfo_numa` and vmstat allow-lists would need widening.
- Alert and recording-rule packaging: as a PrometheusRule bundle in the
  virtualization platform's rule set rather than a custom namespace.
- Multi-cluster / fleet views: rank is per-node; fleet dashboards should
  group by kernel tier number (abstract-distance-derived), which the
  metrics already carry.

## Support surface

- Which kernels are supported (memory-tier sysfs, cgroup v2 numa_stat, THP
  accounting), and what degrades gracefully on older ones (the exporter
  already degrades to a single synthesized tier)?
- Windows guests: host-transparent tiering does not depend on guest
  cooperation, but guest balloon/THP behavior interacts with demotion —
  untested here.
- Live migration under sustained demotion churn — the validation migrated
  under moderate spill; migration during heavy churn is unmeasured.
