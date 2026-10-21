#!/usr/bin/env bash
# Read-only short worker snapshot. Exact comm matching avoids pgrep self-matches.
set -uo pipefail
bounded() { timeout -k 1 3 "$@" 2>&1 || true; }
date -u --iso-8601=seconds
bounded free -m
bounded grep -E 'MemTotal|MemFree|FilePages' /sys/devices/system/node/node{0,1}/meminfo
bounded cat /proc/pressure/memory
bounded cat /sys/kernel/mm/numa/demotion_enabled
bounded grep -E '^pgdemote|^pswp|^oom_kill' /proc/vmstat
ps -eo pid,ppid,stat,time,comm | grep -E 'qemu-kvm|vhost-' || true
for pid in $(pgrep -x qemu-kvm); do
  cmd=$(timeout -k 1 2 cat "/proc/$pid/cmdline" | tr '\0' ' ') || continue
  [[ $cmd == *'guest=memory-tier-demo_stress-'* ]] || continue
  echo "### QEMU $pid"
  printf '%s\n' "$cmd" | grep -oE 'guest=[^ ,]+|mem-lock=[^ ]+' || true
  bounded grep -E '^State|^VmLck|^VmRSS|^SigPnd|^ShdPnd|^Mems_allowed_list' "/proc/$pid/status"
  bounded cat "/proc/$pid/stat"
  bounded cat "/proc/$pid/stack"
  cg=$(timeout -k 1 2 awk -F: '$1=="0" {print $3}' "/proc/$pid/cgroup") || continue
  for path in "/sys/fs/cgroup$cg" "$(dirname "/sys/fs/cgroup$cg")"; do
    echo "cgroup=$path"
    for file in cpu.max cpu.stat memory.current memory.max memory.events; do
      echo "$file"; bounded cat "$path/$file"
    done
  done
done
