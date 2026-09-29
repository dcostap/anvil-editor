#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe=tests/lua/ui/_probe
if [ -e "$probe" ]; then
  echo "Probe directory already exists: $probe" >&2
  exit 1
fi
cleanup() {
  rm -rf "$probe"
  for _ in {1..20}; do
    if rm -rf .run-meson-tests/probe 2>/dev/null; then return; fi
    sleep .1
  done
  echo "Could not remove .run-meson-tests/probe" >&2
  return 1
}
trap cleanup EXIT
mkdir -p "$probe"
cp tools/local_find_probe.lua "$probe/local_find.lua"
bash tests/run-lua-tests.sh build-windows-x86_64 . \
  build-windows-x86_64/src/anvil.exe "$probe/local_find.lua" probe
