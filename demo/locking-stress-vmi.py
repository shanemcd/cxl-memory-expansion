#!/usr/bin/env python3
"""Emit an opt-in stress VMI as JSON (accepted by oc apply)."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("name")
p.add_argument("--locked", action="store_true")
p.add_argument("--cpu", default="1")
p.add_argument("--node", default="worker-cxl-0")
p.add_argument("--namespace", default="memory-tier-demo")
p.add_argument("--legacy-unlocked-request", action="store_true", help="Reproduce the first trials' 2Gi unlocked request (2440Mi final budget)")
a = p.parse_args()
workload = Path(__file__).with_name("locking-stress-guest.py").read_text()
cloud = {
    "write_files": [
        {"path": "/usr/local/sbin/locking-stress.py", "permissions": "0755", "content": workload},
        {"path": "/etc/systemd/system/locking-stress.service", "content": "[Unit]\nAfter=network-online.target\n[Service]\nExecStart=/usr/bin/python3 /usr/local/sbin/locking-stress.py\nRestart=no\nMemoryMax=600M\nRuntimeMaxSec=900\n[Install]\nWantedBy=multi-user.target\n"},
    ],
    "runcmd": [["systemctl", "stop", "firewalld"], ["systemctl", "daemon-reload"], ["systemctl", "start", "locking-stress.service"]],
}
# Match the final compute budget: add the same empirical 1Gi allowance
# explicitly to the unlocked control, without changing its guest RAM.
resources = {"cpu": a.cpu, "memory": "2Gi" if not a.locked and a.legacy_unlocked_request else "1Gi"}
memory = {"guest": "1Gi", "maxGuest": "1Gi"}
if a.locked:
    memory["reservedOverhead"] = {"memLock": "Required"}
elif not a.legacy_unlocked_request:
    memory["reservedOverhead"] = {"memLock": "NotRequired", "addedOverhead": "1Gi"}
print(json.dumps({
    "apiVersion": "kubevirt.io/v1", "kind": "VirtualMachineInstance",
    "metadata": {"name": a.name, "namespace": a.namespace,
        "labels": {"locking-stress": "true"},
        "annotations": {"memorytiering.shanemcd.com/policy-class": "tiered"}},
    "spec": {"nodeSelector": {"kubernetes.io/hostname": a.node}, "terminationGracePeriodSeconds": 10,
        "domain": {"resources": {"requests": resources, "limits": resources}, "memory": memory,
            "devices": {"disks": [{"name": "root", "disk": {"bus": "virtio"}}, {"name": "cloudinit", "disk": {"bus": "virtio"}}],
                "interfaces": [{"name": "default", "masquerade": {}, "ports": [{"name": "stress-http", "port": 8080}]}]}},
        "networks": [{"name": "default", "pod": {}}],
        "volumes": [{"name": "root", "containerDisk": {"image": "quay.io/containerdisks/fedora:latest"}},
            {"name": "cloudinit", "cloudInitNoCloud": {"userData": "#cloud-config\n" + json.dumps(cloud)}}]}
}, indent=2))
