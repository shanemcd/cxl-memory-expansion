# CXL memory expansion

Design and working implementation of the minimal feature that makes CXL
memory useful for VM density: **let CXL extend host RAM, make tier state
observable, and let real DRAM pressure drive workload rebalancing.**

The Linux kernel already tiers memory — CXL onboards as a NUMA node, and
under pressure reclaim demotes cold pages from DRAM to the slower tier.
That behavior needs no new placement API. What it needs is to be *visible*
and *reacted to*. This repository specifies that observability and reaction
layer, and demonstrates it end-to-end on a live cluster:

- a VM's cold guest memory demoted to CXL under a bounded reclaim while the
  VM kept running, visible in Prometheus as a per-VM spill ratio;
- a node under 2.6 GiB of memory pressure demoting ~1.2 GiB of cold pages
  off DRAM, with the demotion-rate series capturing the spike;
- the descheduler classifying a node as overutilized at 85% DRAM
  working-set utilization and evicting its VM — which KubeVirt converted
  into a live migration to a healthy node, the VM Running throughout.

All measurements were taken on an emulated CXL node (a CPU-less NUMA node),
which validates software behavior; physical devices remain the arbiter of
performance. No application-level service-level claims are made here.

## The feature in four components

1. **CXL extends RAM.** Enable kernel tiering; no scheduler change, no
   VM-facing API. Cold pages may live on CXL; kernel aging keeps hot pages
   in DRAM.
2. **Metrics.** [memory-tier-exporter](https://github.com/shanemcd/memory-tier-exporter)
   exposes the tier mapping, per-NUMA-node memory (anonymous vs file,
   transparent hugepages included), demotion and promotion counters, memory
   pressure, and per-VM tier attribution — none of which fleet node
   collectors export with default settings.
3. **Recording rules.** Derive the handful of series everything else
   consumes: DRAM working-set ratio, tier utilization, spill, movement
   rates, per-VM attribution.
4. **Descheduler.** Upstream `LowNodeUtilization` pointed at the DRAM
   working-set ratio through its Prometheus query hook: tier-aware
   rebalancing as configuration, evicting VMs into live migrations when a
   node's fast tier fills.

The operating model in one sentence: **size placements so hot working sets
stay within 50–80% of DRAM, watch the measured ratios, and let the
descheduler move VMs when a node crosses its threshold.** For overcommit,
operations are driven by observability, not by per-workload requests.

## Reading map

Start anywhere; each document stands alone.

| Document | What it covers |
|---|---|
| [The problem and the principles](docs/problem-and-principles.md) | first principles: density, the performance gradient, why the kernel is the tiering engine, why observe rather than enforce |
| [MVP design](docs/mvp-design.md) | the four components, the sizing rule, the operating model, success criteria (with what was demonstrated) |
| [Observability design](docs/observability-design.md) | the metric inventory with sources and status, recording rules, alerts, gaps |
| [Descheduler design](docs/descheduler-design.md) | tier-aware rebalancing: the one-query integration, deployment, validated migration, deferred refinements |
| [Scope and alternatives](docs/scope-and-alternatives.md) | everything deliberately not built, and why: DRAM-pinning, scheduler accounting, memory QoS, guest-visible CXL, an operator |
| [Open questions](docs/open-questions.md) | the honest unknowns, led by physical-hardware validation |
| [Research notes](docs/research-notes.md) | verified facts with upstream sources, plus live-validation findings |
| [Examples](examples/) | deployable recording rules, alerts, descheduler policy and deployment (as validated), and a one-line upstream TLS fix |
| [Demo](demo/) | the capture tool and the recorded evidence for every measured claim |

## What exists vs. what is proposed

| Component | Status |
|---|---|
| memory-tier-exporter | implemented, unit-tested, deployed as a DaemonSet, scraped by platform Prometheus |
| Recording rules + alerts | implemented, applied to the cluster, validated live (alert states observed) |
| Tier-aware descheduler | deployed as configuration on upstream v0.37 + a one-line TLS patch; automated live migration demonstrated |
| Upstream contributions (TLS fix, CA path, collector defaults) | patches documented, not submitted |
| Physical-CXL validation, taint refinement, spill-aware eviction choice | open — see [open questions](docs/open-questions.md) |

## Repository conventions

- Documentation is written for readers with no access to internal context:
  no ticket references, no internal shorthand, self-contained explanations
  from first principles.
- Measured claims carry their scope (emulated CXL, which node, which phase
  of the recorded run). Proposals are labeled as proposals.
- The two implementation repositories (this design repository and the
  exporter) are structured to be acceptable upstream: Apache-2.0 licensing
  posture, conventional Go layout, tested parsers, documented deployment.
