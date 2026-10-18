# Scope, and alternatives deliberately deferred

The MVP in this repository is intentionally small: CXL extends RAM, the
kernel tiers it, metrics make tier state visible, recording rules derive the
signals, and the descheduler reacts. This document records the larger design
space around that MVP, and why each adjacent mechanism was *deferred* rather
than built — with the reasoning an architect owes the next person who picks
any of these up.

The pattern across all of them: they add per-workload tier *contracts*, and
per-workload contracts are where this problem space gets expensive — in
upstream coordination, in enforcement mechanisms, and in operational
complexity — for value that the observability-driven default already
delivers for most workloads.

## Deferred: per-workload DRAM residency ("opt-out of CXL")

**The idea.** A workload declares "my memory must stay in DRAM" and the
platform enforces it — the natural expression of the latency-sensitive
minority, in the same opt-out style as swap usage controls.

**Why deferred.** The operating system cannot currently guarantee it, and
pretending otherwise is worse than not offering it:

- Linux cpuset masks restrict *allocation*, not *residency*: reclaim-driven
  demotion can still move pages between tiers — the kernel's own
  documentation describes demotion ignoring or only partially respecting
  those masks, and pages shared with another cgroup can move regardless.
  (Verified on the validation cluster: a DRAM-masked workload's cold pages
  demoted to the CXL node with the mask held.)
- Mechanisms that *can* deliver it — memory locking, dedicated hugepage
  pools — are heavyweight, capacity-fragmenting, and operationally
  expensive (pool sizing, reboots to resize, separate scheduling budget).
- The enforcement surface (admission control, capacity accounting, backing
  preparation, migration coordination) is a project of its own.

**The interim answer.** The sizing rule (hot set within 50–80% of DRAM) plus
per-VM spill metrics plus tier-aware rebalancing: a latency-sensitive VM is
protected *operationally* — watched and moved — rather than *mechanically*.
Honest, and deliverable now. A future placement class can build the real
mechanism on locking or hugepages when a workload truly needs it.

## Deferred: scheduler-level DRAM accounting

**The idea.** Report DRAM and CXL as separate resources so the scheduler can
place "DRAM-bound" workloads by fast-tier capacity — the strict version of
the sizing rule.

**Why deferred.**

- Kubernetes reports a node's ordinary memory as one `memory` resource; when
  CXL onboards as system RAM, requests and capacities silently include both
  tiers. Splitting them means changing the node status API, the scheduler's
  resource model, or inventing a new extended resource — every option is a
  long upstream coordination path (the swap precedent: years of layer
  fighting before node-level memory posture became workable).
- Dynamic Resource Allocation (DRA) can express "claim 8 GiB of DRAM" — but
  DRA is workload-request-centric by construction: every pod must claim, so
  a fleet-wide policy change means touching every workload object. It fits
  accelerators; it fits poorly transparent system RAM.
- Double-accounting traps are everywhere: a pod requesting both `memory`
  (which includes CXL) and a DRAM resource counts its footprint twice in
  any straightforward accounting.

**What the MVP does instead.** The scheduler keeps placing by summed memory
— which is exactly right for capacity, since CXL *is* usable memory. The
DRAM fraction is enforced by planning plus reaction, not by a second
resource type. If upstream Kubernetes ever grows memory-tier awareness
(swap opened that door), the metrics and rules here are the ready-made
inputs.

## Deferred: memory QoS integration

Cgroup-level memory controls (`memory.min`, `memory.high`) predate CXL and
are specified against a DRAM-plus-swap world. Applied to CXL-extended
nodes, "memory" silently includes the slower tier, so a `memory.min`
reservation meant as DRAM protection is not one, and a `memory.high` limit
interacts with demotion in non-obvious ways (reclaim above the limit can
demote rather than throttle — measured on the validation cluster: a
96 MiB `memory.high` moved the workload's anonymous pages to CXL while it
kept running, with throttling events). Extending those interfaces to be
tier-aware (or HMAT-distance-aware) is upstream kernel and Kubernetes work
worth advocating for, and worth doing *before* building product surface on
the current semantics.

## Deferred: guest-visible CXL (in-guest tiering)

Exposing CXL devices to guests so guest OSes tier their own memory is a
different product: it requires Type-3 device emulation, guest driver
support (uneven across guest operating systems), and solves a different
problem (guest memory management) than host density. Host-transparent
tiering — the approach here — needs none of it and is where the density
value is.

## Deferred: a tiering operator / policy CRD

An operator managing tier policy classes (gold/silver/bronze memory
classes, administrator-defined ratios) is the natural *next* productization
step once the observability loop is proven: policy belongs to the
infrastructure, classes give administrators vocabulary, and admission
control can enforce defaults. But an operator without the underlying
enforcement mechanisms (see above) would be policy theater. The MVP's
cluster-administrator-owned thresholds in the descheduler profile are the
honest version of the same governance, expressed in configuration that
already works.

## Deferred: proactive demotion controllers

The lab used bounded `memory.reclaim` writes as a deterministic demotion
dial, and one could build a controller that proactively demotes cold pages
to keep DRAM headroom. Deferred because the kernel already does this under
ordinary pressure (MGLRU aging picks the cold pages), and a userspace
controller re-deriving hot/cold decisions the kernel makes continuously has
historically underperformed the kernel's own reclaim. The metrics here
would inform such a controller if measurements ever show the kernel's
defaults are wrong for VM fleets.

## Explicitly rejected: userspace page movers

Rebuilding tier placement in userspace (per-page hot/cold tracking outside
the kernel) was explored by the industry and repeatedly converged back to
kernel-native tiering for this use case. The MVP treats the kernel as the
tiering engine and spends its complexity budget on visibility and reaction
instead.
