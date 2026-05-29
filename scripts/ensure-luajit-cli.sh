#!/usr/bin/env bash
set -euo pipefail

build_dir="${1:-build-windows-x86_64}"
luajit_exe="$build_dir/subprojects/luajit/src/luajit.exe"
luajit_target="subprojects/luajit/src/luajit.exe"

if [[ -x "$luajit_exe" ]]; then
  echo "LuaJIT developer CLI is available: $luajit_exe"
  exit 0
fi

echo "LuaJIT developer CLI is missing: $luajit_exe"

if [[ ! -f "$build_dir/build.ninja" ]]; then
  echo "Build directory is not configured yet; skipping LuaJIT CLI recovery."
  exit 0
fi

echo "Trying to build LuaJIT developer CLI..."
if ninja -C "$build_dir" "$luajit_target"; then
  if [[ -x "$luajit_exe" ]]; then
    echo "LuaJIT developer CLI is available: $luajit_exe"
    exit 0
  fi
fi

echo "LuaJIT CLI target was not available. Refreshing stale LuaJIT subproject..."
meson subprojects purge --confirm luajit
meson setup "$build_dir" --reconfigure
ninja -C "$build_dir" "$luajit_target"

if [[ ! -x "$luajit_exe" ]]; then
  echo "Failed to create LuaJIT developer CLI: $luajit_exe" >&2
  exit 1
fi

echo "LuaJIT developer CLI is available: $luajit_exe"
