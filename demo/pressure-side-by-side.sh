#!/bin/bash
# Side-by-side memory-pressure proof for the memory-tiering demo fleet.
#
# Runs ON the CXL worker node (as root) while the demo VMs are up.
# A watermark-aware presser hovers node-0 (DRAM) free memory just above the
# kernel's low watermark, forcing sustained reclaim+demotion, while showing:
#   - demo-mlock     (gold-lock class, mlock backing): VmLck + anon stay on node 0
#   - demo-dram-only (gold-hp class, hugepages backing): Huge pages stay on node 0
#   - demo-tiered    (tiered class, control): anon pages demote to node 1 (CXL)
#
# Usage: sudo bash pressure-side-by-side.sh [budget_MB=7168] [window_s=240] [hold_s=60]
set -u
BUDGET_MB=${1:-7168}
WINDOW_S=${2:-240}
HOLD_S=${3:-60}
UNIT=memtier-press

node_free_mb() { local n=$1; awk -v n="$n" 'BEGIN{p="Node " n " MemFree"} $0 ~ p {printf "%d", $4/1024}' /sys/devices/system/node/node$n/meminfo; }

vm_pid() {
  for Q in $(pgrep -f qemu-kvm); do
    case "$(tr '\0' ' ' < /proc/$Q/cmdline 2>/dev/null)" in *"_$1,"*) echo "$Q"; return 0;; esac
  done
  return 1
}

anon_placement() { # $1 = pid -> "N0_MB N1_MB"
  python3 - "$1" <<'PY'
import sys
n0 = n1 = 0
try:
    for line in open(f"/proc/{sys.argv[1]}/numa_maps"):
        if "anon=" not in line:
            continue
        for tok in line.split():
            if tok.startswith("N0="): n0 += int(tok[3:])
            elif tok.startswith("N1="): n1 += int(tok[3:])
except FileNotFoundError:
    pass
print(f"{n0//1024} {n1//1024}")
PY
}

sample() {
  local t=$(date +%T) n0=$(node_free_mb 0) n1=$(node_free_mb 1)
  local ks=$(awk '/pgdemote_kswapd/{print $2}' /proc/vmstat) dr=$(awk '/pgdemote_direct/{print $2}' /proc/vmstat)
  echo "=== $t  node0_free=${n0}MB node1_free=${n1}MB  pgdemote(kswapd/direct)=${ks}/${dr}"
  for V in demo-mlock demo-dram-only demo-tiered demo-tier-dra; do
    local P; P=$(vm_pid "$V") || continue
    local VL=$(( $(awk '/^VmLck/{print $2}' /proc/$P/status) / 1024 ))
    local HS=$(numastat -p "$P" 2>/dev/null | awk '/^Huge/{printf "%s/%s", $2, $3}')
    read A0 A1 <<< "$(anon_placement "$P")"
    echo "    $V pid=$P VmLck=${VL}MB Huge(N0/N1)=${HS}MB anon(N0/N1)=${A0}/${A1}MB mems=$(awk '/Mems_allowed_list/{print $2}' /proc/$P/status)"
  done
}

echo "# presser: budget=${BUDGET_MB}MB window=${WINDOW_S}s hold=${HOLD_S}s"
echo "--- baseline"
sample

cat > /tmp/memtier-press.py <<'PY'
import time, sys
budget_mb, window_s, hold_s = (int(x) for x in sys.argv[1:4])

def n0free():  # kB
    for line in open('/sys/devices/system/node/node0/meminfo'):
        if line.startswith('Node 0 MemFree'):
            return int(line.split()[3])
    return 0

def n0low():  # sum of Node 0 zone low watermarks, kB
    s, in0 = 0, False
    for line in open('/proc/zoneinfo'):
        if line.startswith('Node 0, zone'): in0 = True
        elif line.startswith('Node '): in0 = False
        if in0 and line.strip().startswith('low '):
            s += int(line.split()[1])
    return s * 4

low = n0low(); guard = low + 16 * 1024  # kB, hover just above the watermark
buf = bytearray(); alloc_mb = 0
end = time.time() + window_s
while time.time() < end and alloc_mb < budget_mb:
    free = n0free()
    if free < guard:
        time.sleep(5)  # let kswapd demote + recover, then press again
        continue
    step = 256 if free > low + 512 * 1024 else 32  # MB
    chunk = bytearray(step * 1024 * 1024)
    for i in range(0, len(chunk), 4096):
        chunk[i] = 1
    buf += chunk
    alloc_mb += step
    time.sleep(3)
print(f"allocated {alloc_mb}MB, node0_free={n0free()}kB, holding {hold_s}s", flush=True)
time.sleep(hold_s)
PY
systemd-run --unit=$UNIT --collect -p AllowedMemoryNodes=0 \
  python3 /tmp/memtier-press.py "$BUDGET_MB" "$WINDOW_S" "$HOLD_S" >/dev/null 2>&1

echo "--- pressure ramp + hold (sampling every 10s)"
for _ in $(seq 1 $(( HOLD_S / 10 + 18 ))); do
  sleep 10
  systemctl is-active --quiet $UNIT || break
  sample
done
journalctl -u $UNIT --no-pager -n 1 2>/dev/null | tail -1

echo "--- after release"
sleep 5
sample
echo "# done"
