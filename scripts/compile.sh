#!/bin/bash
set -e

# CPU-based parallelism can exhaust Windows commit memory during native builds.
jobs="${ANVIL_BUILD_JOBS:-2}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "ANVIL_BUILD_JOBS must be a positive integer." >&2
  exit 1
fi

exec meson compile -j "$jobs" "$@"
