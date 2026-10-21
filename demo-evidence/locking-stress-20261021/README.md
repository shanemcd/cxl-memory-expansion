# Locking stress and teardown tests

Date: 2026-10-21

KubeVirt build: `mt-locking-452d0b5a04`, source [452d0b5a04](https://github.com/shanemcd/kubevirt/commit/452d0b5a045e720a4af31f80f24a75e437d24c52). Worker kernel: `6.12.0-211.64.1.cxltest.el10.x86_64`, with emulated CXL and `CONFIG_CXL_REGION_INVALIDATION_TEST=y`. Guest: Fedora 44, kernel `6.19.10-300.fc44.x86_64`.

## Workload and controls

Each disposable VMI has 1 GiB guest RAM, `maxGuest: 1Gi`, the existing `tiered` class, and masquerade networking. Cloud-init starts a bounded Python service that touches 384 MiB of guest memory, repeatedly hashes it, and serves concurrent HTTP uploads/downloads. A worker-side client uses two connections per guest, sending 1 MiB and receiving 2 MiB per completed cycle. Traffic stays active while ordinary VMI deletion is requested with a 10-second guest grace period.

The locked arm requests `reservedOverhead.memLock: Required`; the unlocked arm does not lock memory. Runtime captures verify `mem-lock=on/off` and nonzero/zero `VmLck`. No DRA placement or DRAM-only guarantee is asserted.

The first two pairs have nearly matched compute-container memory budgets: 2438 MiB locked and 2440 MiB unlocked. The unlocked request was 2 GiB to compensate for the restored build's empirical 1 GiB locked allowance; this also adds 2 MiB of calculated page-table overhead. The pressure pair instead uses `addedOverhead: 1Gi` on the unlocked arm, giving exactly matched 2438 MiB budgets. Original generated manifests are preserved; use `--legacy-unlocked-request` to reproduce the first two unlocked shapes with the current generator.

## Results

| Case | CPU quota per compute / pod | Observed workload | Teardown |
|---|---|---|---|
| Locked and unlocked, no node pressure | 1 / 1.02 CPUs | About 19.5 GiB per guest before deletion; populated memory and CPU hashing | Both deleted in the same five-second observation window; no remaining test QEMU/vhost processes |
| Locked and unlocked, no node pressure | 100m / 120m | 3.53 / 3.64 GiB combined application upload/download payload; heavy CPU throttling captured | Both deleted in the same 25-second observation window; no remaining test QEMU/vhost processes |
| Locked and unlocked, with DRAM pressure | 100m / 120m | 7.21 / 7.50 GiB payload across warmup and pressure; presser at 7.25 GiB before deletion, about 8 GiB during shutdown | Both deleted in the same 25-second observation window; no remaining test QEMU/vhost processes |

The 100m guests took several minutes to reach application readiness. Initial connection errors are boot-time observations, not proof of a kernel hang. Traffic counters reset when the bounded client was restarted; preserve invocation boundaries when summing bytes. Errors after deletion are expected.

The pressure snapshot shows node 0 free memory at 176 MiB, with continuous guest traffic and both arms alive. A later ramp sample immediately before deletion shows about 159 MiB free. Cumulative kswapd demotion increased from zero before the pressure ramps to 872,957 pages after deletion, about 3.33 GiB; direct demotion increased by 70 pages. This is aggregate host demotion, not a measurement of which guest's pages moved. The presser reached its full 10 GiB cap only **after** both VMIs had been deleted, so that peak is not evidence of testing live guests against a 10 GiB allocation.

No hang was reproduced. Neither CPU-quota adjustment nor a worker restart was used. The final check found all three nodes Ready, all 34 cluster operators Available and not Degraded, the original three demo names Running/Ready, no stress pods, and the restored descheduler available at one replica. `demo/verify.sh` reported `ALL CHECKS PASSED`.

One pre-existing `demo-tiered` launcher was evicted by the descheduler after it was resumed and was recreated successfully. The pressure pair was already gone; this did not cause its teardown result. The event is preserved in `eviction-events.txt`.

## Pressure isolation and limits

The descheduler was temporarily scaled to zero for the pressure phase, with its original replica count saved, to prevent automatic evictions from confounding the requested teardown. The annotation `descheduler.alpha.kubernetes.io/evict: "false"` is **not** a protection mechanism in this descheduler: the default evictor tests annotation presence rather than parsing its value. The new generator omits it, and the existing VM example was corrected in [memory-tier-operator commit 9c19803](https://github.com/shanemcd/memory-tier-operator/commit/9c19803). The live `demo-tiered` VM template annotation was also removed. Pausing the descheduler avoids relying on annotation propagation or eviction preferences.

The pressure helper keeps separate allocation chunks rather than copying an ever-growing buffer. It limits the allocation budget to 10 GiB, stops allocating near node 0's low watermark plus 8 MiB, and releases pressure if global `MemAvailable` falls below 1536 MiB. Its systemd unit independently caps memory, CPU, and runtime and makes the helper the preferred OOM victim. This remains a disruptive lab test, not a production diagnostic. `pressure-preflight.txt` preserves an initial ramp with a 32 MiB guard; `pressure-ramp.txt` contains the final ramp with an 8 MiB guard and 16 MiB final allocation steps, allowing a small crossing of the low watermark to exercise reclaim.

## Repeating a case

Use the lab kubeconfig explicitly and adapt the namespace, node selector, and containerdisk image. The generator's default unlocked arm matches the locked allowance through `addedOverhead`.

```sh
export KUBECONFIG=/path/to/lab/kubeconfig
cd cxl-memory-expansion
python3 demo/test_locking_stress.py
python3 demo/locking-stress-vmi.py stress-lock --locked --cpu=100m | oc apply -f -
python3 demo/locking-stress-vmi.py stress-open --cpu=100m | oc apply -f -
oc -n memory-tier-demo wait vmi/stress-lock vmi/stress-open --for=condition=Ready --timeout=120s
oc -n memory-tier-demo get pods -l locking-stress=true -o wide
```

VMI Ready does not mean cloud-init or the guest HTTP service is ready. Copy `demo/locking-stress-client.py`, `demo/locking-stress-pressure.py`, `demo/locking-stress-snapshot.sh`, and `demo/capture-qemu-forensics.sh` to the test worker's `/tmp/`. Start traffic there, setting `LOCKED_IP` and `OPEN_IP` to the actual launcher pod IPs:

```sh
sudo systemd-run --unit=locking-stress-client --collect \
  -p RuntimeMaxSec=620 -p MemoryMax=128M -p CPUQuota=100% \
  python3 /tmp/locking-stress-client.py 600 "$LOCKED_IP" "$OPEN_IP"
sudo journalctl -u locking-stress-client --no-pager -n 5
sudo bash /tmp/locking-stress-snapshot.sh
```

Confirm completed traffic cycles before beginning the timed load window. For an explicitly separate pressure phase, pause the descheduler from the controller and preserve its replica count:

```sh
DESCHEDULER_REPLICAS=$(oc -n cxl-observability get deploy tier-descheduler -o jsonpath='{.spec.replicas}')
oc -n cxl-observability scale deploy tier-descheduler --replicas=0
```

Keep that shell open for restoration. Then run on the worker:

```sh
sudo systemd-run --unit=locking-stress-pressure --collect \
  -p AllowedMemoryNodes=0 -p MemoryMax=11G -p MemorySwapMax=0 \
  -p CPUQuota=50% -p OOMScoreAdjust=1000 -p RuntimeMaxSec=210 \
  python3 /tmp/locking-stress-pressure.py 10240 150 45
```

Capture exact QEMU PIDs before deletion; the collector also includes their separate vhost worker tasks. Use an outer timeout as well as its per-command timeouts. Never identify a process with a broad `pgrep -f` pattern that can match its own launching shell. From the controller, request ordinary deletion while traffic and any pressure are active:

```sh
oc -n memory-tier-demo delete vmi stress-lock stress-open --timeout=30s
```

If teardown stalls, capture again before changing quotas, force-deleting objects, or rebooting. Stop both transient units on the worker and remove only test VMIs. Restore the descheduler from the controller shell and verify the original demos and cluster afterward:

```sh
oc -n cxl-observability scale deploy tier-descheduler --replicas="$DESCHEDULER_REPLICAS"
oc -n cxl-observability rollout status deploy/tier-descheduler --timeout=60s
```

The guest service stops after 900 seconds even if a controller-side test is interrupted. The client and presser have independent runtime limits. These backstops do not replace cleanup.

## Captures and validation

`*-delete.txt` records controller-side deletion timing; `*-after-delete.txt` records worker processes and counters afterward. `100m-before-delete.txt` and `pressure-before-delete.txt` include per-thread kernel stacks, scheduler state, pending signals, QEMU and separate vhost workers, both container and pod cgroups, and address-space summaries. NUL separators in captured command lines were converted to spaces for readability. `pressure-preflight.txt` and `pressure-ramp.txt` retain the pressure-unit invocation boundaries and sampled allocations; traffic logs retain cumulative application counters and errors. `final-state.txt` and `stack-verify.txt` record cleanup and stack verification.

Local harness validation: `python3 demo/test_locking_stress.py` passes four tests without creating VMs or allocating pressure memory. Shell syntax checks pass for the snapshot and forensic collectors. Evidence was scanned for private-key, bearer-header, and JWT patterns before publication.

## Interpretation

A clean short test does not exclude the earlier long-lived failure or prove locking universally safe. The earlier captured unlocked hangs and their CPU-quota recovery remain separate evidence in [the forensic report](../locking-forensics-20261021/). This experiment tests whether the same symptom appears under controlled memory, CPU, and network load on the restored build.
