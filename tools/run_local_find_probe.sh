#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe=tests/lua/ui/_probe
if [ -e "$probe" ]; then
  echo "Probe directory already exists: $probe" >&2
  exit 1
fi
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe"
cp tools/local_find_probe.lua "$probe/local_find.lua"
bash tests/run-lua-tests.sh build-windows-x86_64 . \
  build-windows-x86_64/src/anvil.exe "$probe/local_find.lua" probe
