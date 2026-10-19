# Memory policy classes on a stock stack

How the two-mode memory policy contract — *tiered* (density, tolerate
demotion) and *dram-only* (latency-critical, resist demotion) — is realized
with unmodified kernel, libvirt, QEMU, KubeVirt and OpenShift components.
This is the continuation of [MVP design](mvp-design.md): the MVP observes
and reacts; this adds *administrator-owned intent* at admission time while
keeping the same enforcement philosophy — mechanisms the platform already
guarantees, verified by measurement instead of trusted blindly.

Scope: demonstrated on the emulated-CXL lab cluster. This validates
software behavior on stock components; it does not measure physical CXL
performance.

## The contract

| | Tiered | DRAMOnly |
|---|---|---|
| Workload owner says | "density is fine, cold memory may live below DRAM" | "my guest memory stays on DRAM" |
| Mechanism | none added — kernel demotion is the mechanism | hugepage-backed guest memory from a DRAM-only pool + Memory Manager Static placement |
| Enforcement | n/a (policy is observability-only) | structural: demotion cannot move hugepages to a node without a hugepage pool |
| Verification | spill ratio is expected > 0 under pressure | `MemoryTierDRAMOnlyWorkloadSpilled` alert on spill > 0 |

Policies are cluster-scoped `MemoryPolicy` objects (default implementation:
[memory-tier-operator](https://github.com/shanemcd/memory-tier-operator),
branch `memory-policy-classes`): `spec.mode` (Tiered/DRAMOnly), `spec.backing`
(Hugepages with size, or MemLock), cluster default flag, and namespace
allow/forbid/force/default rules. Workloads *select* a class with one
annotation; they never name mechanisms. The operator's resolver is
namespace-based authorization, not user-based.

## Admission: fail-closed resolution

A mutating admission webhook intercepts VMI CREATE in namespaces labeled
`memorytiering.shanemcd.com/governed=true`:

1. Resolve the class: explicit selection → namespace rules → cluster
   default. Unknown class, forbidden class, or no resolvable default ⇒
   **deny** with the resolver's message. No silent downgrade.
2. Render the class onto the VMI:
   - *Tiered*: annotations only (`rendered-policy`, `rendered-source`).
   - *DRAMOnly + Hugepages*: `spec.domain.memory.hugepages` (2 Mi) and a
     Guaranteed shape (requests == limits, memory = guest size).
   - *DRAMOnly + MemLock*: refused unless the operator runs with
     `--allow-memlock-backing` — KubeVirt 1.9 silently prunes the
     `reservedOverhead.memLock` field, which would turn a fail-closed
     contract into a silent no-op.
3. Stamp identity labels for observability:
   `memorytiering.shanemcd.com/policy-class` and `policy-mode` on the VMI
   (they propagate to launcher pods and to `kube_pod_labels`).

Webhook TLS comes from a self-signed CA provisioned by
`hack/webhook-certs.sh` (the lab has no cert-manager); the CA bundle is
patched into the MutatingWebhookConfiguration. `failurePolicy: Fail` —
if the webhook is down, governed VMIs do not get created, which is the
correct direction for a fail-closed contract.

Live evidence: [demo-evidence/policy-admission-smoke-test.md](../demo-evidence/policy-admission-smoke-test.md).

## Node configuration: the DRAM-only pool

DRAMOnly is only as good as the pool it draws from:

- **2 Mi hugepage pool, node 0 only** (the DRAM NUMA node): provisioned at
  boot by a MachineConfig-hosted oneshot (`memorytier-hugepages-node0.service`,
  `Before=kubelet.service`) writing
  `/sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages`.
  Boot-kernel-argument pools were rejected because they are not
  NUMA-node-pinned and can land on the slower tier.
- **Memory Manager Static** with `single-numa-node` scope and node-0-only
  `reservedMemory` (from the earlier poc-phase0 KubeletConfig): hugepage
  allocations are served from node 0 and the launcher cgroup's
  `cpuset.mems` is pinned to node 0.
- **Pool size**: 2 Gi (1024 × 2 Mi) on an 8 GiB DRAM node — a knob, not a
  constant; the alert and the resident-by-tier series tell an operator
  whether it needs to grow.

Why this holds structurally: demotion moves pages to the node's demotion
targets, but a hugepage cannot be demoted to a node with no hugepage pool
of that size — and the pool exists only on the DRAM node. KubeVirt
additionally treats hugepage-backed guest memory as locked. Measured: the
pool stayed 100% node-0-resident through a pressure event that demoted
~2.5 GiB node-wide ([demo-evidence/policy-tiering-pressure-demo.md](../demo-evidence/policy-tiering-pressure-demo.md)).

## Verification: observe the contract

Enforcement claims are checked, not trusted:

- `workload:memory_spilled:ratio` (recording rule, from the exporter's
  per-workload NUMA attribution) — the spill fraction per workload.
- `MemoryTierDRAMOnlyWorkloadSpilled` — spill > 0 joined against the
  `policy-mode` label via kube-state-metrics. Observed firing (0.449) on
  the DRAMOnly VM's launcher overhead during the pressure event, and
  resolving after replacement.
- The descheduler input (`node:memory_dram_anon:ratio`) is unchanged —
  tiered-node rebalancing keeps working as in the MVP.

## Honest scope

- **Pod-scoped, not guest-scoped**: the DRAMOnly guarantee covers guest
  memory (hugepage-backed). The launcher pod's ordinary anonymous
  overhead (QEMU, device buffers, ~90 MiB for a 512 MiB guest) is
  demotable like any other workload — measured at 38–45% spill under
  pressure. The alert firing on a DRAMOnly VM means "contract drift at
  the pod level"; for hugepage-backed VMs it is overhead, and it is the
  signal that the *placement* half of the contract should be checked.
- **Weaker than a patched contract**: the kernel offers no per-memcg
  demotion control and cpuset membership does not fence kswapd demotion
  (see [research notes](research-notes.md)); a fail-closed, guest-granular
  contract would need kernel/libvirt changes deliberately out of scope
  here. What stock components give: structural guest-memory immunity
  (hugepages) + admission refusal + after-the-fact detection.
- **Verify-after-fact, not prevent-by-construction, for overhead**: the
  alert notices spill after it happened; nothing prevents it. That is the
  MVP's observe-and-react philosophy applied to the policy layer.
- **MemLock backing is disabled by default** on KubeVirt 1.9 (silent
  pruning); the webhook refuses it rather than pretending.
- **Single-node pool**: the demonstration pins the pool to one node with
  a nodeSelector'd demo pair; a fleet version makes pool size and
  placement per-machine-config-pool knobs.
- **Kernel livelock finding**: during teardown immediately after heavy
  demotion churn, the test kernel (6.12.0-211.64.1.cxltest.el10) hit a
  task_work/signal-delivery livelock that made launcher containers
  unkillable until reboot. Recorded in the pressure-demo evidence; a
  finding against the test kernel, not against this stack.

## Relationship to what was rejected

[Scope and alternatives](scope-and-alternatives.md) records why per-VM
DRAM-residency enforcement was cut from the MVP. This design is the
middle path that emerged: administrator-owned intent, admission-time
rendering of *stock* enforcement mechanisms, and measurement as the
arbiter. The earlier exploration that patched QEMU/libvirt/KubeVirt to
get lock-scope guarantees remains documented separately; it is not
required for this contract.
