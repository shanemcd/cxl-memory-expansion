#!/usr/bin/env python3
"""Worker-side bounded DRAM presser; run in a capped, time-limited systemd unit.

Example (root, test worker only):
systemd-run --unit=locking-stress-pressure --collect -p AllowedMemoryNodes=0 \
  -p MemoryMax=11G -p MemorySwapMax=0 -p CPUQuota=50% -p OOMScoreAdjust=1000 \
  -p RuntimeMaxSec=210 python3 /tmp/locking-stress-pressure.py 10240 150 45
"""
import json
import os
import sys
import time

budget, window, hold = map(int, sys.argv[1:4])
if not (0 < budget <= 10240 and 0 < window <= 1800 and 0 <= hold <= 600):
    raise SystemExit("bounds: budget 1..10240MiB, window 1..1800s, hold 0..600s")


def counters(path):
    result = {}
    for line in open(path):
        key, _, rest = line.partition(":")
        if rest:
            result[key] = int(rest.split()[0])
    return result


def low_kb():
    pages = 0
    node0 = False
    for line in open("/proc/zoneinfo"):
        if line.startswith("Node "):
            node0 = line.startswith("Node 0,")
        if node0 and line.strip().startswith("low "):
            pages += int(line.split()[1])
    return pages * os.sysconf("SC_PAGE_SIZE") // 1024


chunks = []
allocated = 0
end = time.monotonic() + window
# A 16MiB final step may cross LOW by at most 8MiB, waking kswapd.
# A higher guard can stall above LOW; allow a bounded crossing.
guard = low_kb() + 8 * 1024
print(json.dumps({"budget_MiB": budget, "window": window, "hold": hold, "node0_guard_kB": guard}), flush=True)
while time.monotonic() < end and allocated < budget:
    free = counters("/sys/devices/system/node/node0/meminfo")["Node 0 MemFree"]
    available = counters("/proc/meminfo")["MemAvailable"]
    if available < 1536 * 1024:
        print("ABORT: global MemAvailable below 1536MiB; releasing pressure", flush=True)
        sys.exit(2)
    if free < guard:
        time.sleep(1)
        continue
    step = min(64 if free > guard + 256 * 1024 else 16, budget - allocated)
    chunk = bytearray(step * 1024 * 1024)
    for offset in range(0, len(chunk), 4096):
        chunk[offset] = 1
    chunks.append(chunk)
    allocated += step
    if allocated % 256 == 0:
        print(json.dumps({"allocated_MiB": allocated, "node0_free_kB": free, "available_kB": available}), flush=True)
    time.sleep(0.5)
print(json.dumps({"allocated_MiB": allocated, "holding_seconds": hold}), flush=True)
for _ in range(hold):
    if counters("/proc/meminfo")["MemAvailable"] < 1536 * 1024:
        print("ABORT: global available guard during hold", flush=True)
        sys.exit(2)
    time.sleep(1)
print("PRESSURE_DONE", flush=True)
