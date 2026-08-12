#!/usr/bin/env bash
set -euo pipefail

local_app_data=${LOCALAPPDATA:-$HOME/AppData/Local}
if command -v cygpath >/dev/null 2>&1; then
  local_app_data=$(cygpath -u "$local_app_data")
fi
tools="$local_app_data/anvil-build-tools"
version=0.16.0
directory="$tools/zig-x86_64-windows-$version"
archive="$tools/zig-$version.zip"
url="https://ziglang.org/download/$version/zig-x86_64-windows-$version.zip"
sha256=68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e

if [ -x "$directory/zig.exe" ]; then
  printf '%s\n' "$directory"
  exit 0
fi

mkdir -p "$tools"
curl --fail --location --retry 3 --output "$archive" "$url"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check - >&2
rm -rf "$directory"
unzip -q "$archive" -d "$tools"
"$directory/zig.exe" version >&2
printf '%s\n' "$directory"
