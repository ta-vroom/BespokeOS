#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$SCRIPT_DIR/lib.sh"

nix build --impure -o result-v1 --expr '
  let
    flake = builtins.getFlake (toString ./.);
  in
  (flake.nixosConfigurations.appliance.extendModules {
    modules = [
      /tmp/ci-test-module.nix
      { system.image.version = "1.0.0"; }
    ];
  }).config.system.build.image
'
zstd -d -f result-v1/bespokeos_1.0.0.raw.zst -o ./disk-test.raw
chmod 644 ./disk-test.raw

{
  inspect_disk ./disk-test.raw "v1.0.0"
  echo "==== [v1.0.0] build output ===="
  ls -la result-v1/
} 2>&1 | tee /tmp/image-inspect-v100.txt

# Expand raw disk by 6G so systemd-repart can grow Slot A, create empty Slot B, and format root
qemu-img resize -f raw ./disk-test.raw +6G
