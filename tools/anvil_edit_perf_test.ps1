param(
  [string]$Exe = "C:\Projects\c_projects\anvil-portable\anvil.exe",
  [string]$File = "C:\Users\Dario Costa\Desktop\projects\castrosua_legacy\test_project\AGENTS.md",
  [int]$WarmupSeconds = 1,
  [int]$StressSeconds = 15,
  [int]$OpsPerSecond = 30,
  [string]$DisablePlugins = "",
  [switch]$SoftwareRenderer,
  [switch]$KeepOpen,
  [switch]$NoKillExisting,
  [switch]$NoAnalyze,
  [string]$ResultFile = "$env:TEMP\anvil_edit_perf_result.txt",
  [string]$FrameStatsFile = "$env:TEMP\anvil_frame_pacing_stats.csv",
  [string]$D3DStatsFile = "$env:TEMP\anvil_d3d11_stats.csv"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $Exe)) { throw "Anvil exe not found: $Exe" }
if (!(Test-Path -LiteralPath $File)) { throw "Test file not found: $File" }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$File = (Resolve-Path -LiteralPath $File).Path

function Get-AnvilTestProcess {
  Get-Process -Name "anvil" -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $Exe } catch { $false }
  } | Sort-Object StartTime -Descending | Select-Object -First 1
}

if (!$NoKillExisting) {
  Get-Process -Name "anvil" -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $Exe } catch { $false }
  } | ForEach-Object {
    Write-Host "Stopping existing Anvil pid $($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 500
}

Remove-Item -LiteralPath $ResultFile, $FrameStatsFile, $D3DStatsFile -Force -ErrorAction SilentlyContinue

$env:ANVIL_EDIT_PERF_TEST = "1"
$env:ANVIL_EDIT_PERF_WARMUP = "$WarmupSeconds"
$env:ANVIL_EDIT_PERF_SECONDS = "$StressSeconds"
$env:ANVIL_EDIT_PERF_OPS = "$OpsPerSecond"
$env:ANVIL_EDIT_PERF_RESULT_FILE = $ResultFile
$env:ANVIL_EDIT_PERF_FILE = $File
if ($KeepOpen) {
  $env:ANVIL_EDIT_PERF_QUIT = "0"
} else {
  $env:ANVIL_EDIT_PERF_QUIT = "1"
}

$env:ANVIL_TEST_DISABLE_PLUGINS = $DisablePlugins
$env:ANVIL_RAD_PACING = "1"
$env:ANVIL_FRAME_PACING_STATS = "1"
$env:ANVIL_FRAME_PACING_STATS_FILE = $FrameStatsFile
$env:ANVIL_FRAME_PACING_STATS_FLUSH = "1"
$env:ANVIL_D3D11_STATS = "1"
$env:ANVIL_D3D11_STATS_FILE = $D3DStatsFile
$env:ANVIL_D3D11_STATS_FLUSH = "1"
$env:ANVIL_DOCVIEW_STATS = "1"
if ($SoftwareRenderer) {
  $env:ANVIL_RENDERER = "software"
} else {
  Remove-Item Env:\ANVIL_RENDERER -ErrorAction SilentlyContinue
}

Write-Host "Launching $Exe"
Write-Host "File: $File"
if ($DisablePlugins -ne "") { Write-Host "Disabled plugins: $DisablePlugins" }
if ($SoftwareRenderer) { Write-Host "Renderer: software" } else { Write-Host "Renderer: default" }

$p = Start-Process -FilePath $Exe -ArgumentList @($File) -PassThru

$timeout = [Math]::Max(30, $WarmupSeconds + $StressSeconds + 20)
$deadline = (Get-Date).AddSeconds($timeout)
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $ResultFile) { break }
  Start-Sleep -Milliseconds 250
}

$summary = $null
if (Test-Path -LiteralPath $ResultFile) {
  $summary = (Get-Content -LiteralPath $ResultFile -Raw).Trim()
  Write-Host "Performance summary: $summary"
} else {
  Write-Warning "Timed out waiting for result file: $ResultFile"
}

if (!$KeepOpen) {
  $target = Get-AnvilTestProcess
  if ($target -and !$target.HasExited) {
    Write-Host "Stopping Anvil pid $($target.Id)"
    Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Perf result file: $ResultFile"
Write-Host "Frame stats:      $FrameStatsFile"
Write-Host "D3D stats:        $D3DStatsFile"

if (!$NoAnalyze) {
  $analyzer = Join-Path $PSScriptRoot "analyze_frame_pacing_stats.py"
  if (Test-Path -LiteralPath $analyzer) {
    python $analyzer --frame $FrameStatsFile --d3d $D3DStatsFile
  } else {
    Write-Warning "Analyzer missing: $analyzer"
  }
}

if ($summary) { Write-Output $summary }
