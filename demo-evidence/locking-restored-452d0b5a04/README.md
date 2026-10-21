# Restored KubeVirt locking support

Date: 2026-10-21

Source: [shanemcd/kubevirt, commit 452d0b5a04](https://github.com/shanemcd/kubevirt/commit/452d0b5a045e720a4af31f80f24a75e437d24c52), branch `memory-tier-main`.

Image tag: `mt-locking-452d0b5a04`. The restored source tree matches the earlier `4b696a92c0` implementation, with a new history-preserving commit rather than resetting the branch or reusing the mutable `mt` tag.

Restored behavior:

- `reservedOverhead.memLock: Required` emits libvirt `<memoryBacking><locked/></memoryBacking>`.
- The handler falls back to adjusting virtqemud's memlock rlimit when a VMI is already marked Running but QEMU does not exist yet.
- The controller adds the previous empirical 1 GiB launcher allowance for a VMI requiring locking. This is not a newly isolated measurement of locking's physical-memory cost.
- The KubeVirt CR enables `ReservedOverheadMemlock`. Other VMI settings are not automatically changed, and the operator's removed `MemLock` policy class is not restored.

## Verification

Both restored source suites passed:

```sh
cd kubevirt
GOTOOLCHAIN=go1.26.0 go test ./pkg/hypervisor/kvm ./pkg/virt-launcher/virtwrap/converter/compute -count=1
```

The disposable `locking-smoke` VMI used 1 GiB guest memory with `maxGuest: 1Gi`, the existing `tiered` policy class, and one full CPU. The higher CPU allocation deliberately avoids the 100m quota involved in the previous captured failures. The test is about locking support, not a DRAM-only placement guarantee.

Observed:

- Launcher image digest: `sha256:d1e94406d69137f99fcd43018f05a49b4513a5f14e4aa9bea29b134192825545`.
- Compute-container memory request and limit: `2438Mi`.
- Live libvirt XML contained `<locked/>`.
- QEMU arguments contained `-overcommit mem-lock=on`.
- QEMU memlock rlimit was unlimited; `VmLck` was nonzero. `VmLck` measures locked virtual memory, not guest physical RAM.
- The VMI became Ready and deleted successfully afterward.

`smoke-runtime.txt` preserves the output, including an initial unsuccessful `qemu:///system` query followed by the successful `qemu:///session` query required by the non-root launcher.

KubeVirt converged to the new tag with matching target and observed deployment IDs and `ReservedOverheadMemlock` enabled. All three existing demo VMIs were refreshed and became Ready on the same new launcher digest; their policy settings were unchanged. The full `demo/verify.sh` check also passed. See `final-state.txt` and `stack-verify.txt`.

The smoke manifest is preserved here. It is intentionally opt-in and disposable:

```sh
cd cxl-memory-expansion
oc apply -f demo-evidence/locking-restored-452d0b5a04/vmi-locking-smoke.yaml
oc -n memory-tier-demo wait vmi/locking-smoke --for=condition=Ready --timeout=120s
# Inspect the launcher/domain before deleting the test.
oc -n memory-tier-demo delete vmi locking-smoke
```

Use the lab kubeconfig explicitly. Adapt the namespace, node selector, and disk image for another environment. This short smoke test does not establish pressure behavior, long-term lifecycle reliability, or a root cause for the earlier CPU-quota-associated failures. See [the forensic investigation](../locking-forensics-20261021/).
