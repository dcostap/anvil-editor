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
# Zig's own HTTP and Git clients fail on some Windows machines. Fetch each
# missing dependency with curl or git instead, and give Zig the package folder.
# Zig 0.17 keeps a top-level archive folder when it fetches a local archive,
# so unpack the archive first. Fetch outside the project, so Zig does not use
# the project's package folder.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch_package() {
  local url=$1
  local package
  package="$work/$(printf '%s' "$url" | sha256sum | cut -c1-16)"
  rm -rf "$package" "$package.unpacked"
  case "$url" in
    git+https://*)
      local repository=${url#git+}
      local commit=${repository##*#}
      repository=${repository%%#*}
      git init -q "$package"
      git -C "$package" fetch -q --depth 1 "$repository" "$commit"
      # Zig hashes the files as committed, so keep their line endings.
      git -C "$package" -c core.autocrlf=false checkout -q FETCH_HEAD
      rm -rf "$package/.git"
      ;;
    *)
      local archive="$package.archive"
      curl --fail --location --retry 3 --output "$archive" "$url"
      mkdir -p "$package.unpacked"
      case "$url" in
        *.zip) unzip -q "$archive" -d "$package.unpacked" ;;
        *) tar -xf "$archive" -C "$package.unpacked" ;;
      esac
      # Like Zig, drop one top-level folder that holds all entries.
      local entries=("$package.unpacked"/* "$package.unpacked"/.[!.]*)
      local found=()
      for entry in "${entries[@]}"; do [ -e "$entry" ] && found+=("$entry"); done
      if [ "${#found[@]}" -eq 1 ] && [ -d "${found[0]}" ]; then
        mv "${found[0]}" "$package"
      else
        mv "$package.unpacked" "$package"
      fi
      rm -rf "$archive" "$package.unpacked"
      ;;
  esac
  (cd "$work" && "$zig" fetch "$package")
}

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

  urls=$(printf '%s\n' "$output" | grep -oE '(git\+)?https://[^" ]+' | sort -u || true)
  if [ -z "$urls" ]; then exit "$status"; fi

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    fetch_package "$url"
  done <<< "$urls"
done

echo "libghostty-vt dependency fetch did not settle" >&2
exit 1
