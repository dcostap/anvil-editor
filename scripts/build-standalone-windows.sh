#!/bin/bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the Anvil repository root."
  exit 1
fi

source scripts/common.sh

if [[ "$(get_platform_name)" != "windows" ]]; then
  echo "The standalone executable build is only available on Windows."
  exit 1
fi

build_dir="build-windows-x86_64-standalone"
output_dir="dist"
candidate="$output_dir/anvil-candidate.exe"
zig_dir=$(./scripts/ensure-zig.sh)
export PATH="$zig_dir:$PATH"

./scripts/build.sh \
  --builddir "$build_dir" \
  --forcefallback \
  --portable \
  --release \
  --embedded-runtime

mkdir -p "$output_dir"
rm -f "$candidate"
trap 'rm -f "$candidate"' EXIT
strip --strip-all -o "$candidate" "$build_dir/src/anvil.exe"

powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File tests/gui/smoke/standalone-runtime-test.ps1 \
  -AnvilExe "$candidate"

mv -f "$candidate" "$output_dir/anvil.exe"
trap - EXIT

echo
echo "Standalone Anvil is ready:"
echo "  $output_dir/anvil.exe"
