#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$SCRIPT_DIR/lib.sh"

nix build --impure -o result-v2 --expr '
  let
    flake = builtins.getFlake (toString ./.);
  in
  (flake.nixosConfigurations.appliance.extendModules {
    modules = [
      /tmp/ci-test-module.nix
      { system.image.version = "1.0.1"; }
    ];
  }).config.system.build.sysupdate-package
'

{
  echo "==== [v1.0.1] build output ===="
  ls -la result-v2/
  zstd -dc result-v2/bespokeos_1.0.1.nix-store.raw.zst > /tmp/nix-store101.raw
  inspect_store /tmp/nix-store101.raw "v1.0.1"
  rm -f /tmp/nix-store101.raw
} 2>&1 | tee /tmp/image-inspect-v101.txt

rm -rf /tmp/update-srv
mkdir -p /tmp/update-srv
cp result-v2/bespokeos_1.0.1.nix-store.raw.zst /tmp/update-srv/
cp result-v2/bespokeos_1.0.1.efi /tmp/update-srv/

cd /tmp/update-srv
sha256sum -- * > SHA256SUMS
cat SHA256SUMS
setsid nohup python3 -m http.server 8000 --bind 0.0.0.0 > /tmp/http-server.log 2>&1 &
HTTP_PID=$!
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "HTTP_PID=$HTTP_PID" >> "$GITHUB_ENV"
fi
