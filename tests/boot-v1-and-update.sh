#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Copy writable OVMF_VARS so UEFI boot entries persist across reboots
install -m 644 /usr/share/OVMF/OVMF_VARS_4M.fd ./ovmf_vars.fd

QEMU_PID=""
trap 'if [ -n "$QEMU_PID" ]; then kill "$QEMU_PID" 2>/dev/null || true; fi' EXIT

start_qemu /tmp/serial-boot1.log /tmp/serial-boot1.sock -no-reboot

echo "Waiting for v1.0.0 guest SSH..."
if ! wait_ssh 60 /tmp/serial-boot1.log; then
  capture_serial_diagnostics /tmp/serial-boot1.sock /tmp/guest-diag-boot1.txt
  exit 1
fi
capture_guest_diagnostics /tmp/guest-diag-boot1.txt

BOOTED_VER=$(ssh_guest ". /etc/os-release && echo \$IMAGE_VERSION")
echo "Booted Version: $BOOTED_VER"
test "$BOOTED_VER" = "1.0.0"

# 1. Verify systemd-repart.service succeeded on boot without failing on inactive real-root unit
ssh_guest '
  set -euo pipefail
  systemctl status systemd-repart.service --no-pager || true
  test "$(systemctl show -p Result --value systemd-repart.service)" = "success"
  journalctl -b -u systemd-repart.service --no-pager | grep -qE "Finished (systemd-repart\.service|Repartition Root Disk)"
'

# 2. Verify the partition table actually has the '_empty' B slot, nix-store_1.0.0, root, and boot
ssh_guest "lsblk -o NAME,PARTLABEL,PARTTYPE,PARTUUID,SIZE"
ssh_guest "blkid -t PARTLABEL=_empty"
ssh_guest "blkid -t PARTLABEL=nix-store_1.0.0"
ssh_guest "blkid -t PARTLABEL=root"
ssh_guest "blkid -t PARTLABEL=boot"
ssh_guest 'lsblk -no PARTLABEL "$(findmnt -n -f -o SOURCE /nix/store)" | grep -qx nix-store_1.0.0'

# 3. Verify persistent root (/ and /var) and /etc overlay are mounted and write test markers
verify_mounts
ssh_guest 'mkdir -p /var/lib && echo "var-persisted-from-1.0.0" > /var/lib/persist-test'
ssh_guest 'echo "etc-persisted-from-1.0.0" > /etc/persist-etc-test'

# Record how the ESP is mounted on the running v1.0.0 system (useful for debugging UUID mismatches)
ssh_guest 'findmnt /boot; blkid | grep -i vfat; cat /etc/fstab 2>/dev/null || true' | tee /tmp/guest-esp-v100.txt

# 4. Verify systemd-sysupdate sees the empty slot and the remote v1.0.1 update
ssh_guest "systemd-sysupdate components"
ssh_guest "systemd-sysupdate list --verify=no"

# 5. Run the update and verify '_empty' became 'nix-store_1.0.1' and boot-counted UKI exists
ssh_guest "systemd-sysupdate update --verify=no"
ssh_guest "lsblk -o NAME,PARTLABEL,PARTUUID,SIZE"
ssh_guest "blkid -t PARTLABEL=nix-store_1.0.1"
ssh_guest "! blkid -t PARTLABEL=_empty"
ssh_guest 'ESP_DIR=$(bootctl --print-esp-path) && ls -la "$ESP_DIR/EFI/Linux/" && test -f "$ESP_DIR/EFI/Linux/bespokeos_1.0.1+3-0.efi"'

# Power off cleanly so filesystems and EFI vars flush
poweroff_guest "$QEMU_PID"
