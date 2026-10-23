# Tier-aware descheduler: pressure-driven live migration (2-CXL-worker lab, 2026-10-23)

Setup: 4-node lab (master, worker-cxl-0, worker-cxl-1, worker-dram-0). worker-dram-0 has no
CXL tier; worker-cxl-* each expose a 4 GiB emulated CXL region as a second NUMA node.

1. worker-cxl-0 had earlier absorbed a demotion demo (test-vm cold pages moved to its CXL
   node), leaving its DRAM-anon ratio at ~9% (underutilized, real DRAM headroom).
2. A 10 GiB anonymous memory hog (descheduler-demo/dram-hog) ran on worker-dram-0 pinned via
   AllowedMemoryNodes=0... (plain pod, nodeSelector worker-dram-0). With no CXL tier to absorb
   it, worker-dram-0's node:memory_dram_anon:ratio rose to 84%.
3. The tier-aware descheduler (LowNodeUtilization, thresholds 40/70, Prometheus metric
   node:memory_dram_anon:ratio, evict only virt-launcher pods) classified worker-dram-0
   OVERUTILIZED (84% > 70) and worker-cxl-0 UNDERUTILIZED (9% < 40).
4. It evicted the only removable pod on the node: virt-launcher-test-vm-2. KubeVirt's
   eviction interceptor converted the eviction into an evacuation live migration
   (VirtualMachineInstanceMigration kubevirt-evacuation-j5kbq).
5. The migration target scheduled onto worker-cxl-0 (free DRAM capacity after demotion) and
   the migration SUCCEEDED: "The VirtualMachineInstance migrated to node worker-cxl-0."

Result: the VM workload moved from the pressured DRAM-only node to the tiered node whose
cold data had demoted to CXL - the memory-tiering rebalance story end to end.

Files: descheduler-log.txt (classification + eviction lines), migration-j5kbq.yaml,
vmi-test-vm-2-final.yaml (migrationState completed, targetNode worker-cxl-0),
events-test-vm.txt, node-ratios-at-migration.txt, dram-hog-pod.txt.

Reproduction notes:
- The demo VM must NOT pin kubernetes.io/hostname in its nodeSelector: VMI specs are
  immutable, and the migration target inherits the selector, so a hostname pin makes the
  target unschedulable on every other node. Use node-role + preferred nodeAffinity for
  initial placement instead.
- On the CXL nodes the hog could not push dram-anon past ~70%: kernel demotion absorbs
  anonymous cold pages into the CXL tier, capping the ratio at the threshold. The overutilized
  signal therefore arises on the DRAM-only node; the tiered nodes are the migration targets.
- vm stop/start: patch spec.runStrategy Halted/Always (spec.running is rejected as deprecated
  and mutually exclusive with runStrategy).
