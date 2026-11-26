#!/usr/bin/env bash
set -euo pipefail

rm -f /tmp/ci_id_ed25519 /tmp/ci_id_ed25519.pub
ssh-keygen -t ed25519 -f /tmp/ci_id_ed25519 -N ""

cat > /tmp/ci-test-module.nix <<'EOF'
{ lib, ... }:
{
  boot.kernelParams = [ "console=ttyS0,115200n8" ];
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "i6300esb" ];
  boot.initrd.systemd.emergencyAccess = true;

  image.repart.partitions.esp.contents."/loader/loader.conf".source = lib.mkForce (
    builtins.toFile "loader.conf" ''
      timeout 3
    ''
  );

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile /tmp/ci_id_ed25519.pub)
  ];

  systemd.sysupdate.transfers."10-nix-store".Source.Path = "http://10.0.2.2:8000/";
  systemd.sysupdate.transfers."20-boot-image".Source.Path = "http://10.0.2.2:8000/";
}
EOF
