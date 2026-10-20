#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: $0 <build-dir> <source-dir> <anvil-exe> <test-path> <run-name>" >&2
  exit 2
fi

builddir=$(cd "$1" && pwd)
sourcedir=$(cd "$2" && pwd)
anvil_exe_dir=$(cd "$(dirname "$3")" && pwd)
anvil_exe="$anvil_exe_dir/$(basename "$3")"
test_path=$4
run_name=$5
if [ "$#" -ge 6 ] && [ -n "$6" ]; then
  test_path=$6
fi
case "$test_path" in
  runtime/*|ui/*)
    test_path="tests/lua/$test_path"
    ;;
esac

# Keep the project path outside build*/ directories because Anvil's default
# ignore rules intentionally ignore build roots, and some UI tests exercise
# project-relative file opening.
runs_root="$sourcedir/.run-meson-tests"
mkdir -p "$runs_root"

# Remove folders that earlier runs could not delete. No run lasts this long,
# so another active run never loses its folder.
find "$runs_root" -mindepth 1 -maxdepth 1 -type d -mmin +720 \
  -exec rm -rf {} + 2>/dev/null || true

# Each run gets its own folder, so concurrent runs of one suite do not delete
# each other's files.
rundir=$(mktemp -d "$runs_root/$run_name.XXXXXX")
bindir="$rundir/bin"
datadir="$rundir/share/anvil"
workdir="$rundir/work"
userdir="$rundir/user"

# Set ANVIL_TEST_KEEP_RUN=1 to keep the folder for inspection.
cleanup() {
  local status=$?
  cd "$sourcedir"
  if [ -n "${ANVIL_TEST_KEEP_RUN:-}" ]; then
    echo "Kept test run folder: $rundir" >&2
    return "$status"
  fi
  # A Terminal Session host can hold its files for a few seconds after the
  # editor exits. The next run removes a folder that is still held.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    rm -rf "$rundir" 2>/dev/null && break
    sleep 0.5
  done
  return "$status"
}
trap cleanup EXIT

mkdir -p "$bindir" "$datadir" "$datadir/core" "$workdir/tests" "$userdir"

if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; then
  exe_name="anvil.exe"
else
  exe_name="anvil"
fi

cp "$anvil_exe" "$bindir/$exe_name"

for module_name in core compat plugins colors fonts widget treesitter tools models; do
  cp -R "$sourcedir/data/$module_name" "$datadir/"
done
mkdir -p "$datadir/icons"
cp -R "$sourcedir/resources/icons/symbols" "$datadir/icons/"
cp -R "$sourcedir/resources/icons/recent_files" "$datadir/icons/"
cp -R "$sourcedir/resources/icons/file_types" "$datadir/icons/"
if [ -d "$sourcedir/subprojects/colors" ]; then
  cp -a "$sourcedir/subprojects/colors/colors" "$datadir/"
fi
if [ -d "$sourcedir/subprojects/plugins" ]; then
  cp -a "$sourcedir/subprojects/plugins/plugins/"language_* "$datadir/plugins/" 2>/dev/null || true
fi
# List ppm binaries in a directory. The source tree also has a ppm.json
# manifest, and the plugin manager fails to load without a binary.
ppm_binaries() {
  local file
  for file in "$1"/ppm.*; do
    [ -f "$file" ] && [ "${file##*.}" != json ] && printf '%s\n' "$file"
  done
  return 0
}
if [ -d "$sourcedir/subprojects/ppm" ]; then
  ppm_files=$(ppm_binaries "$builddir/subprojects/ppm")
  if [ -z "$ppm_files" ]; then ppm_files=$(ppm_binaries "$sourcedir/subprojects/ppm"); fi
  if [ -n "$ppm_files" ]; then
    cp -a "$sourcedir/subprojects/ppm/plugins/plugin_manager" "$datadir/plugins"
    while IFS= read -r file; do cp -a "$file" "$datadir/plugins/plugin_manager/"; done <<<"$ppm_files"
  fi
  if [ -d "$datadir/plugins/plugin_manager" ]; then
    mkdir -p "$datadir/libraries"
    cp -a "$sourcedir/subprojects/ppm/libraries/json.lua" "$datadir/libraries" 2>/dev/null || true
  fi
fi

cp "$builddir/start.lua" "$datadir/core/"
# Scenario runs and Lua tests share these scene modules as `scenes.<name>`.
cp -R "$sourcedir/tests/scenes" "$datadir/"
if [ -f "$builddir/conpty.dll" ]; then
  mkdir -p "$datadir/conpty"
  cp "$builddir/conpty.dll" "$builddir/OpenConsole.exe" "$datadir/conpty/"
fi

# Keep test fixtures isolated from the source tree. Some Windows UI tests leave
# temp project files until process shutdown; those are discarded with rundir.
cp -R "$sourcedir/tests/lua" "$workdir/tests/"
if [ -d "$sourcedir/tests/fixtures" ]; then
  cp -R "$sourcedir/tests/fixtures" "$workdir/tests/"
fi
if [ -f "$builddir/subprojects/luajit/src/luajit.exe" ]; then
  cp "$builddir/subprojects/luajit/src/luajit.exe" "$workdir/tests/fixtures/terminal argv's.exe"
fi

cd "$workdir"
export SDL_VIDEO_DRIVER="${SDL_VIDEO_DRIVER:-dummy}"
export ANVIL_HEADLESS_TEST=1
export ANVIL_USERDIR="$userdir"
if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; then
  export USERPROFILE="$userdir"
fi

"$bindir/$exe_name" test "$test_path"
