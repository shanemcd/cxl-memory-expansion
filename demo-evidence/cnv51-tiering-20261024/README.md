# Tiering + descheduler on stock OpenShift Virtualization 5.1 (2026-10-24)

Cluster: fresh OCP 5.1 nightly (4 nodes: cxl-master-0, worker-cxl-0/1 with
2 GiB... 4 GiB emulated CXL tiers each, worker-dram-0 DRAM-only), **stock CNV
5.1 Konflux nightly v5.1.0.rhel9-2989** (no modified KubeVirt),
memory-tier-exporter + recording rules, tier-aware descheduler (upstream
PR #1932 build pr1932-64fecb114).

## CXL residency (test-vm)

- test-vm: 8 GiB guest (maxGuest pinned 8 GiB), fedora containerdisk,
  cloud-init guest hog touching 7000 MiB, 256 MiB kept hot. Placed on
  worker-cxl-0.
- Kernel demotion moved the guest's cold pages to the CXL tier with no
  placement enforcement at all (no DRA driver; QEMU Mems_allowed_list 0-1):
  natural pressure alone (node0 free ~576 MB) demoted 89k pages, then a
  3-minute watermark-hugging presser on node 0 raised pgdemote_kswapd to
  617,607 pages (~2.4 GiB) and filled the 4 GiB CXL tier
  (node1 MemUsed 4,000,728 kB of 4,194,304 kB).
- Exporter (node_memory_tier_workload_anon_bytes): test-vm QEMU anon
  5.6 GiB on node 0 (DRAM) + 2.5 GiB on node 1 (CXL, tier 22).

## Descheduler-driven live migration (test-vm-2)

- test-vm-2: 2 GiB guest, preferred placement worker-dram-0 (DRAM-only),
  evictionStrategy LiveMigrate, broad worker nodeSelector (no hostname pin —
  VMI specs are immutable and the migration target inherits them).
- dram-hog (10 GiB anon, requests 128Mi / limit 10600Mi Burstable) on
  worker-dram-0 drove node:memory_dram_anon:ratio to 78%.
- Descheduler (LowNodeUtilization 40/70, evicts only kubevirt.io=virt-launcher)
  classified worker-dram-0 overutilized and evicted
  virt-launcher-test-vm-2 at 15:56:06; kubevirt's eviction interceptor
  created evacuation migration kubevirt-evacuation-jfsmq.
- Migration Succeeded in ~2 min; test-vm-2 now Running on worker-cxl-1
  (migrationState.targetNode=worker-cxl-1, completed=true).

## Files

- descheduler-log.txt — classification + eviction lines
- migration-jfsmq.yaml, test-vm-2-migrationstate.json, vmis-final.yaml
- test-vm.yaml, test-vm-2.yaml, dram-hog.yaml — workload specs
- worker-cxl-0-demotion-counters.txt — pgdemote counters + CXL tier usage

## Reproduction notes

- The memory-hog binary is in the memory-tier-exporter image
  (/usr/local/bin/memory-hog, flags -total-mb/-hot-mb); cross-namespace pulls
  need a system:image-puller rolebinding for the namespace's service accounts
  in cxl-observability.
- For controlled pressure windows, pause the descheduler and restore the
  replica count afterwards; the descheduler.alpha.kubernetes.io/evict
  annotation is NOT an opt-out (key presence bypasses filters).
