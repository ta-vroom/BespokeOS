#!/usr/bin/env bash
# Shared CI/test helper functions for building, inspecting, booting, and verifying images.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_OPTS=(
  -i /tmp/ci_id_ed25519
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=3
  -p 2222
)

FATAL_RE='You are in emergency mode|Give root password for maintenance|Please configure the system|Kernel panic|Timed out waiting for device|Failed to start .*(systemd-repart\.service|Repartition Root Disk)'

ssh_guest() {
  ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"
}

# wait_ssh <tries> <serial-log>
# Polls SSH, but bails out immediately if the serial log shows a fatal boot state.
wait_ssh() {
  local tries=$1 log=$2 i
  for ((i = 0; i < tries; i++)); do
    if ssh_guest true 2>/dev/null; then
      return 0
    fi
    if grep -qaE "$FATAL_RE" "$log" 2>/dev/null; then
      echo "::error::Fatal boot state detected in $log"
      grep -aE "$FATAL_RE" "$log" | head -n 10 || true
      return 2
    fi
    sleep 2
  done
  echo "::error::SSH never came up (see $log)"
  echo "---- last ssh -v attempt ----"
  ssh -v "${SSH_OPTS[@]}" root@127.0.0.1 true 2>&1 || true
  return 1
}

# inspect_store <erofs-image-or-device> <label>
# Mounts a nix-store erofs partition read-only and reports its contents.
inspect_store() {
  local src=$1 label=$2
  echo "---- [$label] nix-store contents ----"
  sudo mkdir -p /mnt/inspect
  if sudo mount -t erofs -o loop,ro "$src" /mnt/inspect 2>/dev/null; then
    local store_dir=/mnt/inspect
    if [ -d /mnt/inspect/nix/store ]; then
      store_dir=/mnt/inspect/nix/store
    fi
    ls -la "$store_dir" 2>/dev/null | head -n 40 || true
    echo "Total store paths: $(find "$store_dir" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)"
    sudo umount /mnt/inspect
  else
    echo "(could not mount $src as erofs)"
    file "$src" || true
  fi
}

# inspect_disk <raw-disk> <label>
inspect_disk() {
  local disk=$1 label=$2 loop p
  echo "==== [$label] disk layout ===="
  loop=$(sudo losetup -Pf --show "$disk")
  sudo sfdisk -d "$loop" || true
  for p in "${loop}"p*; do
    echo "-- $p --"
    sudo blkid "$p" || true
  done
  for p in "${loop}"p*; do
    if [ "$(sudo blkid -s TYPE -o value "$p" 2>/dev/null)" = "erofs" ]; then
      inspect_store "$p" "$label"
      break
    fi
  done
  sudo losetup -d "$loop"
}

# capture_guest_diagnostics <out-file>
# Captures failed systemd units, repart/bless-boot status, mounts, and boot errors.
capture_guest_diagnostics() {
  local out=$1
  ssh_guest '
    echo "==== systemctl --failed ===="
    systemctl --failed --no-pager --no-legend || true
    echo "==== failed unit journals ===="
    systemctl --failed --no-pager --no-legend | while read -r u _; do
      [ -n "$u" ] || continue
      echo "--- $u ---"
      journalctl -b -u "$u" -n 50 --no-pager || true
    done
    echo "==== systemd-repart & systemd-bless-boot status ===="
    systemctl status systemd-repart.service systemd-bless-boot.service --no-pager -l || true
    echo "==== lsblk & findmnt ===="
    lsblk -o NAME,PARTLABEL,FSTYPE,MOUNTPOINTS,SIZE || true
    findmnt || true
    echo "==== journalctl -b -p err ===="
    journalctl -b -p err -n 200 --no-pager || true
  ' > "$out" 2>&1 || true
}

# capture_serial_diagnostics <sock> <out-file>
capture_serial_diagnostics() {
  local sock=$1 out=$2
  "$LIB_DIR/capture-serial-diagnostics.py" "$sock" "$out" || true
}

# start_qemu <serial-log> <serial-sock> [extra-qemu-args...]
# Launches QEMU in the background and sets QEMU_PID.
start_qemu() {
  local serial_log=$1 serial_sock=$2
  shift 2
  : > "$serial_log"
  rm -f "$serial_sock"

  qemu-system-x86_64 \
    --machine q35 \
    -enable-kvm -cpu host -m 2G -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=./ovmf_vars.fd \
    -drive file=./disk-test.raw,format=raw,if=virtio \
    -net nic,model=virtio \
    -device i6300esb -watchdog-action reset \
    -net user,hostfwd=tcp:127.0.0.1:2222-:22 \
    -display none -monitor none \
    -chardev "socket,id=ser0,path=${serial_sock},server=on,wait=off,logfile=${serial_log},logappend=on" \
    -serial chardev:ser0 \
    "$@" &
  QEMU_PID=$!
}

# poweroff_guest <qemu-pid>
poweroff_guest() {
  local pid=$1 i
  ssh_guest "systemctl poweroff" || true
  for i in {1..45}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
  done
  wait "$pid" || true
}

verify_mounts() {
  ssh_guest 'test "$(findmnt -n -f -o SOURCE /)" = "$(blkid -t PARTLABEL=root -o device)"'
  ssh_guest 'test "$(findmnt -n -f -o SOURCE -T /var)" = "$(blkid -t PARTLABEL=root -o device)"'
  ssh_guest 'test "$(findmnt -n -f -o FSTYPE /etc)" = "overlay"'
}
