#!/usr/bin/env bash
set -euo pipefail

# Meson can start Git's bash with MSYS2's tools first on PATH. Tools from the
# other runtime can fail to start under load, drop environment variables and
# rewrite arguments, so this bash's own tools come first.
PATH="/usr/bin:$PATH"

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

# Runs live in the temp folder, outside the source tree. Editors and tools
# that watch the repo can hold new files open there, and a held file fails
# saves and deletes in the tests. Anvil's default ignore rules also ignore
# build*/ roots, which some UI tests open files from. ANVIL_TEST_RUNS_ROOT
# picks another folder.
# Bash rewrites TEMP to /tmp, and Git's and MSYS2's bash map /tmp to different
# folders. LOCALAPPDATA keeps its Windows form.
if [ -n "${LOCALAPPDATA:-}" ]; then
  backslash='\'
  temp_root="${LOCALAPPDATA//"$backslash"//}/Temp"
else
  temp_root=${TMPDIR:-/tmp}
fi
runs_root="${ANVIL_TEST_RUNS_ROOT:-$temp_root/anvil-lua-tests}"
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
logdir="$rundir/logs"

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

mkdir -p "$bindir" "$datadir" "$datadir/core" "$workdir/tests" "$userdir" "$logdir"

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
cp -R "$sourcedir/resources/icons/agents" "$datadir/icons/"
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

# Each test file runs in its own editor process with its own user folder.
# State that one file leaves behind, such as open Views, watchers, worker jobs
# or Terminal Sessions, cannot change the result of a later file.
files=()
if [ -d "$test_path" ]; then
  while IFS= read -r file; do files+=("$file"); done \
    < <(find "$test_path" -type f -name '*.lua' | LC_ALL=C sort)
elif [ -f "$test_path" ]; then
  files=("$test_path")
else
  echo "Test path '$test_path' was not found." >&2
  exit 1
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "No Lua test files in '$test_path'." >&2
  exit 1
fi

# ANVIL_TEST_JOBS sets how many files run at once. ANVIL_TEST_FILE_TIMEOUT
# stops a file that hangs, so the rest of the run still reports.
jobs=${ANVIL_TEST_JOBS:-4}
file_timeout=${ANVIL_TEST_FILE_TIMEOUT:-300}

run_file() {
  local index=$1 file=$2 status=0
  local file_userdir="$userdir/$index"
  if mkdir -p "$file_userdir"; then
    ANVIL_USERDIR="$file_userdir" USERPROFILE="$file_userdir" \
      timeout --kill-after=10 "$file_timeout" "$bindir/$exe_name" test "$file" \
      >"$logdir/$index.log" 2>&1 || status=$?
  else
    status=255
  fi
  echo "$status" >"$logdir/$index.status"
}

total=0 passed=0 failed=0 skipped=0 broken_files=()
next_report=0
started_at=$SECONDS

# Print finished files in file order, so the output reads the same at any job
# count.
summary_pattern='Ran ([0-9]+) tests in [0-9]+ files: ([0-9]+) passed, ([0-9]+) failed, ([0-9]+) skipped'

report_finished() {
  local index file status line summary f
  while [ "$next_report" -lt "${#files[@]}" ] && [ -f "$logdir/$next_report.status" ]; do
    index=$next_report
    file=${files[$index]}
    status=$(cat "$logdir/$index.status" 2>/dev/null || true)
    [[ $status =~ ^[0-9]+$ ]] || status=255
    [ -f "$logdir/$index.log" ] || : >"$logdir/$index.log"
    cat "$logdir/$index.log"
    summary=
    while IFS= read -r line || [ -n "$line" ]; do
      [[ $line =~ $summary_pattern ]] && summary=$line
    done <"$logdir/$index.log"
    f=0
    if [[ $summary =~ $summary_pattern ]]; then
      f=${BASH_REMATCH[3]}
      total=$((total + BASH_REMATCH[1])) passed=$((passed + BASH_REMATCH[2]))
      failed=$((failed + f)) skipped=$((skipped + BASH_REMATCH[4]))
    fi
    if [ -z "$summary" ] || { [ "$status" -ne 0 ] && [ "$f" -eq 0 ]; }; then
      # The process ended without a result for every test: a crash, a timeout,
      # or an error outside a test.
      local reason="exited with status $status"
      [ "$status" -eq 124 ] && reason="timed out after ${file_timeout}s"
      echo "FAIL $file > the test process $reason"
      broken_files+=("$file")
      total=$((total + 1)) failed=$((failed + 1))
    fi
    next_report=$((next_report + 1))
  done
}

running=0
for index in "${!files[@]}"; do
  if [ "$running" -ge "$jobs" ]; then
    wait -n || true
    running=$((running - 1))
    report_finished
  fi
  run_file "$index" "${files[$index]}" &
  running=$((running + 1))
done
wait || true
# A file whose status was never written still counts as a failed file.
for index in "${!files[@]}"; do
  [ -f "$logdir/$index.status" ] || echo 255 >"$logdir/$index.status"
done
report_finished

echo ""
echo "Ran $total tests in ${#files[@]} files: $passed passed, $failed failed, $skipped skipped ($((SECONDS - started_at))s, $jobs at once)"
if [ "${#broken_files[@]}" -gt 0 ]; then
  echo "Files that ended without results:"
  printf '  %s\n' "${broken_files[@]}"
fi
[ "$failed" -eq 0 ]
