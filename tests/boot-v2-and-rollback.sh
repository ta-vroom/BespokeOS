#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$SCRIPT_DIR/lib.sh"

verify_bless_boot() {
  ssh_guest '
    set -euo pipefail
    ESP_DIR=$(bootctl --print-esp-path)
    BOOTCOUNT_VAR="/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    test -f "$BOOTCOUNT_VAR"
    tr -d "\0" < "$BOOTCOUNT_VAR" | grep -qaF "bespokeos_1.0.1+2-1.efi"
    BLESS_STATUS=$(systemd-bless-boot status || true)
    if [ "$BLESS_STATUS" != "good" ]; then
      test -f "$ESP_DIR/EFI/Linux/bespokeos_1.0.1+2-1.efi"
    fi
    systemctl start systemd-bless-boot.service
    systemd-bless-boot status | grep -qx good
    ls -la "$ESP_DIR/EFI/Linux/"
    test -f "$ESP_DIR/EFI/Linux/bespokeos_1.0.1.efi"
    ! find "$ESP_DIR/EFI/Linux/" -maxdepth 1 -name "bespokeos_1.0.1+*.efi" | grep -q .
  '
}

QEMU_PID=""
trap 'if [ -n "$QEMU_PID" ]; then kill "$QEMU_PID" 2>/dev/null || true; fi' EXIT

# No -no-reboot here: the rollback test relies on the guest rebooting itself.
start_qemu /tmp/serial-boot2.log /tmp/serial-boot2.sock

echo "Waiting for v1.0.1 guest SSH..."
if ! wait_ssh 60 /tmp/serial-boot2.log; then
  capture_serial_diagnostics /tmp/serial-boot2.sock /tmp/guest-diag-boot2.txt
  exit 1
fi
capture_guest_diagnostics /tmp/guest-diag-boot2.txt

ssh_guest "lsblk -o NAME,PARTLABEL,PARTUUID,MOUNTPOINTS,SIZE"
BOOTED_VER=$(ssh_guest ". /etc/os-release && echo \$IMAGE_VERSION")
echo "Booted Version: $BOOTED_VER"
test "$BOOTED_VER" = "1.0.1"

# Verify /nix/store is backed by nix-store_1.0.1 (Slot B)
ssh_guest 'lsblk -no PARTLABEL "$(findmnt -n -f -o SOURCE /nix/store)" | grep -qx nix-store_1.0.1'

# Verify persistent root (/var) and /etc overlay survived the A -> B slot switch
verify_mounts
ssh_guest 'test "$(cat /var/lib/persist-test)" = "var-persisted-from-1.0.0"'
ssh_guest 'test "$(cat /etc/persist-etc-test)" = "etc-persisted-from-1.0.0"'

# Verify systemd-boot decremented +3-0 -> +2-1 and systemd-bless-boot marks it good
if ! verify_bless_boot; then
  echo "::group::bless-boot diagnostics"
  ssh_guest '
    systemctl status systemd-bless-boot.service --no-pager -l
    journalctl -b -u systemd-bless-boot.service --no-pager
    bootctl status --no-pager
    ls -la /sys/firmware/efi/efivars | grep -iE "loader|bootcount" || true
    cat /sys/firmware/efi/efivars/LoaderBootCountPath-* 2>/dev/null | tr -d "\0"; echo
    findmnt /boot || true
    ls -la "$(bootctl --print-esp-path)/EFI/Linux/" || true
    systemd-bless-boot status || true
  ' || true
  echo "::endgroup::"
  exit 1
fi

# Simulate a bad update with 1 try remaining that reboots before boot-complete.target
ssh_guest 'ESP_DIR=$(bootctl --print-esp-path) && mv "$ESP_DIR/EFI/Linux/bespokeos_1.0.1.efi" "$ESP_DIR/EFI/Linux/bespokeos_1.0.1+1-0.efi"'
ssh_guest 'set -euo pipefail
mkdir -p /etc/systemd/system.control/systemd-bless-boot.service.d
cat > /etc/systemd/system.control/systemd-bless-boot.service.d/simulate-bad-update.conf <<'\''EOF'\''
[Unit]
ConditionOSRelease=IMAGE_VERSION=1.0.1
Before=sshd.service multi-user.target
FailureAction=reboot-force

[Service]
ExecStart=
ExecStart=/bin/sh -c false
EOF
sync'

echo "Rebooting into simulated bad v1.0.1 (+1-0) to verify automatic fallback to v1.0.0..."
# Mark where the rollback boot output starts so failures can be located in the serial log
echo "=== CI: issuing reboot into simulated bad v1.0.1 ===" >> /tmp/serial-boot2.log
ssh_guest "touch /run/awaiting-rollback && systemctl reboot" || true

for _ in {1..30}; do
  ssh_guest "test -f /run/awaiting-rollback" 2>/dev/null || break
  sleep 1
done
if ! wait_ssh 75 /tmp/serial-boot2.log; then
  capture_serial_diagnostics /tmp/serial-boot2.sock /tmp/guest-diag-boot2.txt
  exit 1
fi

ROLLBACK_VER=$(ssh_guest ". /etc/os-release && echo \$IMAGE_VERSION")
echo "Rolled-back Booted Version: $ROLLBACK_VER"
test "$ROLLBACK_VER" = "1.0.0"

# Verify fallback booted Slot A (nix-store_1.0.0), v1.0.1 exhausted tries (+0-1), and state stayed intact
ssh_guest 'lsblk -no PARTLABEL "$(findmnt -n -f -o SOURCE /nix/store)" | grep -qx nix-store_1.0.0'
ssh_guest 'ESP_DIR=$(bootctl --print-esp-path) && ls -la "$ESP_DIR/EFI/Linux/" && test -f "$ESP_DIR/EFI/Linux/bespokeos_1.0.1+0-1.efi"'
ssh_guest 'test "$(cat /var/lib/persist-test)" = "var-persisted-from-1.0.0"'
ssh_guest 'test "$(cat /etc/persist-etc-test)" = "etc-persisted-from-1.0.0"'

# Clean up the simulated bad-update override from the persistent /etc overlay
ssh_guest "rm -f /etc/systemd/system.control/systemd-bless-boot.service.d/simulate-bad-update.conf && rmdir --ignore-fail-on-non-empty /etc/systemd/system.control/systemd-bless-boot.service.d && systemctl daemon-reload"

poweroff_guest "$QEMU_PID"
