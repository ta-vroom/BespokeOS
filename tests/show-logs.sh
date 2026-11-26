#!/usr/bin/env bash
set -euo pipefail

for f in /tmp/guest-diag-boot1.txt /tmp/guest-diag-boot2.txt; do
  if [ -s "$f" ]; then
    echo "::group::$f"
    cat "$f"
    echo "::endgroup::"
  fi
done
for f in /tmp/serial-boot1.log /tmp/serial-boot2.log; do
  echo "::group::tail of $f"
  tail -n 300 "$f" 2>/dev/null || echo "(missing)"
  echo "::endgroup::"
done
echo "::group::image inspection"
cat /tmp/image-inspect-v100.txt /tmp/image-inspect-v101.txt 2>/dev/null || echo "(missing)"
echo "::endgroup::"
