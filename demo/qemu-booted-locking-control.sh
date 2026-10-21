#!/usr/bin/env bash
# Run inside diagnostic sandbox after copying a Fedora containerdisk to BASE.
# Arguments: on|off (locking), on|off (kernel vhost networking), TERM|KILL.
# Direct-QEMU control, not a complete libvirt/KubeVirt reproduction.
set -euo pipefail
lock=${1:?locking on|off}; vhost=${2:?vhost on|off}; method=${3:-TERM}
[[ $lock =~ ^(on|off)$ && $vhost =~ ^(on|off)$ && $method =~ ^(TERM|KILL)$ ]] || exit 2
base=${BASE:-/tmp/forensic-fedora-base.img}
ulimit -l unlimited
id="lock-$lock-vhost-$vhost-$method"
log="/tmp/$id.serial.log"
ip tuntap add dev testtap mode tap
ip link set testtap up
trap 'ip link del testtap 2>/dev/null || true' EXIT
printf '\n## %s %s\n' "$id" "$(date -u +%FT%TZ)"
/usr/libexec/qemu-kvm -name "$id" -machine q35 -accel kvm -cpu host \
  -m 1G -smp 1 -nodefaults -display none -monitor none \
  -serial "file:$log" -overcommit "mem-lock=$lock" \
  -drive "file=$base,format=qcow2,if=virtio,snapshot=on" \
  -netdev "tap,id=n0,ifname=testtap,script=no,downscript=no,vhost=$vhost" \
  -device virtio-net-pci,netdev=n0 > "/tmp/$id.stderr" 2>&1 &
pid=$!
echo "pid=$pid"
sleep 25
if ! kill -0 "$pid" 2>/dev/null; then cat "/tmp/$id.stderr"; exit 1; fi
grep -E 'State|VmLck|VmRSS|Mems_allowed_list' "/proc/$pid/status"
tail -15 "$log"
kill -"$method" "$pid"
for i in {1..10}; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
  echo "STUCK pid=$pid; preserve pod for host-side capture"
  # Do not remove networking while a stuck process still owns it.
  trap - EXIT
  exit 2
fi
wait "$pid" || true
echo EXITED
cat "/tmp/$id.stderr"
