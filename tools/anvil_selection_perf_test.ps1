param(
  [string]$Exe = "C:\Projects\c_projects\anvil-portable\anvil.exe",
  [string]$File = "C:\Users\Darius\Downloads\sqlite3.c",
  [int]$WarmupSeconds = 2,
  [int]$HugeSeconds = 2,
  [int]$StressSeconds = 10,
  [int]$CursorCount = 1000,
  [int]$DragLines = 8,
  [int]$HugeLines = 8000,
  [int]$ScrollLinesPerFrame = 1,
  [switch]$KeepOpen,
  [switch]$NoAnalyze,
  [switch]$NoKillExisting,
  [string]$FrameStatsFile = "$env:TEMP\anvil_frame_pacing_stats.csv",
  [string]$D3DStatsFile = "$env:TEMP\anvil_d3d11_stats.csv"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $Exe)) { throw "Anvil exe not found: $Exe" }
if (!(Test-Path $File)) { throw "Test file not found: $File" }
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

Remove-Item -LiteralPath $FrameStatsFile, $D3DStatsFile -Force -ErrorAction SilentlyContinue

$env:ANVIL_RAD_PACING = "1"
$env:ANVIL_FRAME_PACING_STATS = "1"
$env:ANVIL_FRAME_PACING_STATS_FILE = $FrameStatsFile
$env:ANVIL_FRAME_PACING_STATS_FLUSH = "1"
$env:ANVIL_D3D11_STATS = "1"
$env:ANVIL_D3D11_STATS_FILE = $D3DStatsFile
$env:ANVIL_D3D11_STATS_FLUSH = "1"
$env:ANVIL_DOCVIEW_STATS = "1"

$env:ANVIL_SELECTION_STRESS_TEST = "1"
$env:ANVIL_SELECTION_STRESS_SECONDS = "$StressSeconds"
$env:ANVIL_SELECTION_STRESS_HUGE_SECONDS = "$HugeSeconds"
$env:ANVIL_SELECTION_STRESS_CURSORS = "$CursorCount"
$env:ANVIL_SELECTION_STRESS_DRAG_LINES = "$DragLines"
$env:ANVIL_SELECTION_STRESS_HUGE_LINES = "$HugeLines"
$env:ANVIL_SELECTION_STRESS_SCROLL_LINES = "$ScrollLinesPerFrame"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32SelectionPerfInput {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  public const int SW_RESTORE = 9;
}
"@

Write-Host "Launching $Exe $File"
$p = Start-Process -FilePath $Exe -ArgumentList @($File) -PassThru

$deadline = (Get-Date).AddSeconds(15)
$hwnd = [IntPtr]::Zero
$targetProcess = $p
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 100
  try { $targetProcess.Refresh() } catch {}

  if ($targetProcess.HasExited -or $targetProcess.MainWindowHandle -eq 0) {
    $found = Get-AnvilTestProcess
    if ($found) { $targetProcess = $found }
  }

  if (!$targetProcess.HasExited -and $targetProcess.MainWindowHandle -ne 0) {
    $hwnd = $targetProcess.MainWindowHandle
    break
  }
}
if ($hwnd -eq [IntPtr]::Zero) { throw "Timed out waiting for Anvil main window" }

[Win32SelectionPerfInput]::ShowWindow($hwnd, [Win32SelectionPerfInput]::SW_RESTORE) | Out-Null
[Win32SelectionPerfInput]::SetForegroundWindow($hwnd) | Out-Null

$totalSeconds = $WarmupSeconds + $HugeSeconds + $StressSeconds + 1
Write-Host "Warmup ${WarmupSeconds}s, huge selection ${HugeSeconds}s, multiline selection stress ${StressSeconds}s"
Write-Host "Cursors=$CursorCount DragLines=$DragLines HugeLines=$HugeLines ScrollLinesPerFrame=$ScrollLinesPerFrame"
Start-Sleep -Seconds $totalSeconds

if (!$KeepOpen) {
  try { $targetProcess.Refresh() } catch {}
  if (!$targetProcess.HasExited) {
    Write-Host "Stopping Anvil pid $($targetProcess.Id)"
    Stop-Process -Id $targetProcess.Id -Force
    Wait-Process -Id $targetProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
  }
}

Write-Host "Frame stats: $FrameStatsFile"
Write-Host "D3D stats:   $D3DStatsFile"

if (!$NoAnalyze) {
  $analyzer = Join-Path $PSScriptRoot "analyze_frame_pacing_stats.py"
  if (Test-Path $analyzer) {
    python $analyzer --frame $FrameStatsFile --d3d $D3DStatsFile
  } else {
    Write-Warning "Analyzer missing: $analyzer"
  }
}
