[CmdletBinding()]
param(
  [string]$BuildDir = "build-windows-x86_64",
  [string]$RealRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$ReportPath,
  [switch]$SkipRealRoot,
  [int]$MediumFiles = 240,
  [int]$MediumSymbolsPerFile = 20,
  [int]$LargeFiles = 1000,
  [int]$LargeSymbolsPerFile = 40,
  [int]$CancelFiles = 400,
  [int]$CancelSymbolsPerFile = 40,
  [int]$TimeoutSeconds = 300,
  [int]$MesonTimeoutMultiplier = 5
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$build = if ([System.IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $repo $BuildDir }
if (-not (Test-Path $build)) { throw "Build directory does not exist: $build" }
if (-not $ReportPath) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $ReportPath = Join-Path $repo "tools\baselines\treesitter-project-index-$stamp.lua"
} elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
  $ReportPath = Join-Path $repo $ReportPath
}
$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$mingwBin = "C:\msys64\mingw64\bin"
if (-not (Test-Path $mingwBin)) { throw "MinGW tool directory does not exist: $mingwBin" }
$env:PATH = $mingwBin + [System.IO.Path]::PathSeparator + $env:PATH
$meson = Get-Command (Join-Path $mingwBin "meson.exe") -ErrorAction SilentlyContinue
if (-not $meson) { throw "meson.exe was not found under $mingwBin" }

if ($SkipRealRoot) {
  Remove-Item Env:ANVIL_TS_BENCH_REAL_ROOT -ErrorAction SilentlyContinue
} else {
  $env:ANVIL_TS_BENCH_REAL_ROOT = (Resolve-Path $RealRoot).Path
}
$env:ANVIL_TS_BENCH_REPORT = [System.IO.Path]::GetFullPath($ReportPath)
$env:ANVIL_TS_BENCH_MEDIUM_FILES = $MediumFiles
$env:ANVIL_TS_BENCH_MEDIUM_SYMBOLS_PER_FILE = $MediumSymbolsPerFile
$env:ANVIL_TS_BENCH_LARGE_FILES = $LargeFiles
$env:ANVIL_TS_BENCH_LARGE_SYMBOLS_PER_FILE = $LargeSymbolsPerFile
$env:ANVIL_TS_BENCH_CANCEL_FILES = $CancelFiles
$env:ANVIL_TS_BENCH_CANCEL_SYMBOLS_PER_FILE = $CancelSymbolsPerFile
$env:ANVIL_TS_BENCH_TIMEOUT_SECONDS = $TimeoutSeconds

$caseCount = if ($SkipRealRoot) { 3 } else { 4 }
$minimumMultiplier = [Math]::Ceiling((($TimeoutSeconds * $caseCount) + 60) / 120.0)
$effectiveTimeoutMultiplier = [Math]::Max($MesonTimeoutMultiplier, $minimumMultiplier)

Push-Location $repo
try {
  & $meson.Source test -C $build "anvil:lua-runtime" --timeout-multiplier $effectiveTimeoutMultiplier --test-args "tests/lua/benchmarks/treesitter_project_index.lua" --print-errorlogs
  if ($LASTEXITCODE -ne 0) { throw "Tree-sitter Project index benchmark failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

if (-not (Test-Path $ReportPath)) { throw "Benchmark completed without writing report: $ReportPath" }
Write-Host "Tree-sitter Project index benchmark report: $ReportPath"
