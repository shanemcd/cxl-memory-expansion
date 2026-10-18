# MemoryPolicy admission governance — live smoke test (2026-10-18)

Operator: `memory-tier-operator:v8` (branch `memory-policy-classes`,
commit after 632e88c), deployed from `deploy/install.yaml` in namespace
`kubevirt-mt`. Webhook TLS via `hack/webhook-certs.sh` (self-signed CA,
secret `memory-tier-operator-webhook`, caBundle patched into
MutatingWebhookConfiguration `memory-policy-vmi-mutation`). Governance
scope: namespaces labeled `memorytiering.shanemcd.com/governed=true`
(labeled: `cxl-observability`). Policy classes: `deploy/memory-policy-examples/00-classes.yaml`.

All commands run with the lab admin kubeconfig (`oc` at
`/root/ocp-install-cxl/bin/oc`). Cluster: emulated-CXL lab (worker-cxl-0:
node0=8GiB DRAM + node1=4GiB emulated CXL).

## 1. Operator + webhook health

```
$ oc -n kubevirt-mt rollout status deploy/memory-tier-operator
deployment "memory-tier-operator" successfully rolled out

$ oc -n kubevirt-mt logs deploy/memory-tier-operator | tail
{"msg":"Starting webhook server"}
{"msg":"Updated current TLS certificate","cert":"/tmp/k8s-webhook-server/serving-certs/tls.crt"}
{"msg":"Serving webhook server","host":"","port":9443}
```

## 2. Happy path: `tiered` class selected via annotation

```
$ cat /tmp/smoke-tiered.yaml   (VMI smoke-tiered, cxl-observability, guest 256Mi,
  annotation memorytiering.shanemcd.com/policy-class: tiered)
$ oc create -f /tmp/smoke-tiered.yaml
virtualmachineinstance.kubevirt.io/smoke-tiered created

$ oc -n cxl-observability get vmi smoke-tiered -o jsonpath='{.metadata.annotations}'
{
    "memorytiering.shanemcd.com/policy-class": "tiered",
    "memorytiering.shanemcd.com/rendered-policy": "tiered",
    "memorytiering.shanemcd.com/rendered-source": "selection"
}
```

Tiered renders no mechanism (kernel demotion is the mechanism) — the
webhook records the decision on annotations for observability.

## 3. Fail-closed: unknown class refused

```
$ sed 's/tiered/does-not-exist/' /tmp/smoke-tiered.yaml | oc create -f -
Error from server (Forbidden): error when creating: admission webhook
"vmi-mutation.memorytier.shanemcd.com" denied the request:
unknown memory policy class: "does-not-exist"
```

No silent downgrade: the create is refused with the resolver's message.

## 4. DRAMOnly + Hugepages class: mechanism rendered

```
$ sed 's/tiered/gold-hp/' /tmp/smoke-tiered.yaml | oc create -f -    (guest 512Mi)
virtualmachineinstance.kubevirt.io/smoke-gold-hp created

$ oc -n cxl-observability get vmi smoke-gold-hp -o jsonpath='{...}'
annotations: rendered-policy=gold-hp, rendered-source=selection
resources={"limits":{"cpu":"100m","memory":"512Mi"},
            "requests":{"cpu":"100m","memory":"512Mi"}}   # Guaranteed shape
hugepages={"pageSize":"2Mi"}                               # class backing

$ oc -n cxl-observability get events --field-selector reason=FailedScheduling
0/3 nodes are available: 3 Insufficient hugepages-2Mi.
```

The scheduler honestly reports the missing prerequisite: no node yet
exposes a 2Mi hugepage pool (Memory Manager Static + node-0 pool = the
cluster-config phase, not yet applied). The admission path — selection,
resolution, rendering, denial — is complete; placement is the next phase.

## 5. Cleanup

Both smoke VMIs deleted (`oc -n cxl-observability delete vmi
smoke-tiered smoke-gold-hp`). Policy classes, governed-namespace label,
CRD, operator, and webhook configuration remain deployed.
