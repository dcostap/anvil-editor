#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <zig> <ghostty-source> <output-library>" >&2
  exit 2
fi

zig=$1
source_dir=$2
output_library=$3
case "$output_library" in
  /*|[A-Za-z]:*) ;;
  *) output_library="$(pwd)/$output_library" ;;
esac

cd "$source_dir"
deps_dir=.anvil-zig-deps
mkdir -p "$deps_dir"

for attempt in $(seq 1 40); do
  set +e
  output=$("$zig" build -Demit-lib-vt=true -Dsimd=false -Doptimize=ReleaseFast 2>&1)
  status=$?
  set -e
  printf '%s\n' "$output"
  if [ "$status" -eq 0 ]; then
    cp zig-out/lib/ghostty-vt-static.lib "$output_library"
    exit 0
  fi

  urls=$(printf '%s\n' "$output" | grep -oE 'https://[^" ]+' | sort -u || true)
  if [ -z "$urls" ]; then exit "$status"; fi

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    name=$(printf '%s' "$url" | sha256sum | cut -c1-16)
    case "$url" in
      *.tar.gz) extension=.tar.gz ;;
      *.tar.xz) extension=.tar.xz ;;
      *.tgz) extension=.tgz ;;
      *.zip) extension=.zip ;;
      *) extension=.tar.gz ;;
    esac
    archive="$deps_dir/$name$extension"
    curl --fail --location --retry 3 --output "$archive" "$url"
    "$zig" fetch "$archive"
  done <<< "$urls"
done

echo "libghostty-vt dependency fetch did not settle" >&2
exit 1
