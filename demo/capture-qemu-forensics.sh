#!/usr/bin/env bash
# Run as root on a worker. Read-only, bounded capture; supply exact QEMU PIDs.
# Usage: sudo bash capture-qemu-forensics.sh PID [PID...]
set -uo pipefail
if (( $# == 0 )); then echo 'Supply exact QEMU PIDs' >&2; exit 2; fi
run() { printf '\n###'; printf ' %q' "$@"; printf '\n'; timeout -k 2 8 "$@" 2>&1 || true; }
run date -u --iso-8601=seconds
run uname -a
run uptime
run free -m
run cat /proc/pressure/memory
run cat /proc/vmstat
run cat /sys/kernel/mm/numa/demotion_enabled
run journalctl -k -n 150 --no-pager
for pid in "$@"; do
  [[ $pid =~ ^[0-9]+$ ]] || exit 2
  printf '\n## PID %s\n' "$pid"
  run ps -p "$pid" -o pid,ppid,stat,time,wchan:40,comm
  for name in cmdline status stat schedstat limits cgroup syscall stack; do
    run cat "/proc/$pid/$name"
    printf '\n'
  done
  cg=$(timeout 3 awk -F: '$1=="0" {print $3}' "/proc/$pid/cgroup" 2>/dev/null) || cg=''
  if [[ -n $cg && $cg == /* ]]; then
    path="/sys/fs/cgroup$cg"
    while [[ $path == /sys/fs/cgroup* ]]; do
      for name in memory.current memory.max memory.events memory.stat memory.numa_stat memory.pressure cpu.max cpu.stat cpu.weight cpuset.cpus.effective cpuset.mems cpuset.mems.effective cgroup.freeze cgroup.events; do
        run cat "$path/$name"
      done
      [[ $path != /sys/fs/cgroup ]] || break
      path=$(dirname "$path")
    done
  fi
  for thread in /proc/"$pid"/task/*; do
    [[ -d $thread ]] || continue
    printf '\n### Thread %s\n' "${thread##*/}"
    for name in comm status schedstat stack wchan syscall; do run cat "$thread/$name"; done
  done
  # Address-space readers can block behind mmap_lock. Keep them last and bounded.
  run cat "/proc/$pid/numa_maps"
  run cat "/proc/$pid/smaps_rollup"
done
