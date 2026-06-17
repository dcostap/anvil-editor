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
rundir="$sourcedir/.run-meson-tests/$run_name"
bindir="$rundir/bin"
datadir="$rundir/share/anvil"
workdir="$rundir/work"
userdir="$rundir/user"

rm -rf "$rundir"
mkdir -p "$bindir" "$datadir" "$datadir/core" "$workdir/tests" "$userdir"

if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; then
  exe_name="anvil.exe"
else
  exe_name="anvil"
fi

cp "$anvil_exe" "$bindir/$exe_name"

for module_name in core compat plugins colors fonts treesitter; do
  cp -R "$sourcedir/data/$module_name" "$datadir/"
done

if [ -d "$sourcedir/subprojects/widget" ]; then
  cp -a "$sourcedir/subprojects/widget" "$datadir/"
fi
if [ -d "$sourcedir/subprojects/colors" ]; then
  cp -a "$sourcedir/subprojects/colors/colors" "$datadir/"
fi
if [ -d "$sourcedir/subprojects/plugins" ]; then
  cp -a "$sourcedir/subprojects/plugins/plugins/"language_* "$datadir/plugins/" 2>/dev/null || true
fi
if [ -d "$sourcedir/subprojects/ppm" ]; then
  if [ -d "$builddir/subprojects/ppm" ] && ls "$builddir"/subprojects/ppm/ppm.* >/dev/null 2>&1; then
    cp -a "$sourcedir/subprojects/ppm/plugins/plugin_manager" "$datadir/plugins"
    cp -a "$builddir"/subprojects/ppm/ppm.* "$datadir/plugins/plugin_manager/"
  elif ls "$sourcedir"/subprojects/ppm/ppm.* >/dev/null 2>&1; then
    cp -a "$sourcedir/subprojects/ppm/plugins/plugin_manager" "$datadir/plugins"
    cp "$sourcedir"/subprojects/ppm/ppm.* "$datadir/plugins/plugin_manager/" 2>/dev/null || true
  fi
  if [ -d "$datadir/plugins/plugin_manager" ]; then
    mkdir -p "$datadir/libraries"
    cp -a "$sourcedir/subprojects/ppm/libraries/json.lua" "$datadir/libraries" 2>/dev/null || true
  fi
fi

cp "$builddir/start.lua" "$datadir/core/"

# Keep test fixtures isolated from the source tree. Some Windows UI tests leave
# temp project files until process shutdown; those are discarded with rundir.
cp -R "$sourcedir/tests/lua" "$workdir/tests/"

cd "$workdir"
export SDL_VIDEO_DRIVER="${SDL_VIDEO_DRIVER:-dummy}"
export ANVIL_USERDIR="$userdir"
if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; then
  export USERPROFILE="$userdir"
fi

"$bindir/$exe_name" test "$test_path"
