#!/usr/bin/env bash
# Run inside qemu-locking-control-pod.yaml's container. No guest OS or network.
# This isolates memory locking, not the full KubeVirt/libvirt lifecycle.
set -euo pipefail
ulimit -l unlimited
for lock in off on; do
  for method in TERM KILL; do
    printf '\n## lock=%s teardown=%s time=%s\n' "$lock" "$method" "$(date -u +%FT%TZ)"
    /usr/libexec/qemu-kvm -name "locking-control-$lock-$method" \
      -machine q35 -accel kvm -cpu host -m 1G -S -nodefaults \
      -display none -monitor none -serial none -net none \
      -overcommit "mem-lock=$lock" > "/tmp/qemu-$lock-$method.log" 2>&1 &
    pid=$!
    sleep 3
    if ! kill -0 "$pid" 2>/dev/null; then cat "/tmp/qemu-$lock-$method.log"; exit 1; fi
    echo "pid=$pid"
    grep -E 'State|VmLck|VmRSS|Mems_allowed_list' "/proc/$pid/status"
    cg=$(awk -F: '$1=="0" {print $3}' /proc/self/cgroup)
    cat "/sys/fs/cgroup$cg/memory.current" "/sys/fs/cgroup$cg/memory.max" 2>/dev/null || true
    kill -"$method" "$pid"
    for i in {1..10}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "STUCK pid=$pid; preserving for host-side capture"
      exit 2
    fi
    wait "$pid" || true
    echo 'EXITED'
    cat "/tmp/qemu-$lock-$method.log"
  done
done
