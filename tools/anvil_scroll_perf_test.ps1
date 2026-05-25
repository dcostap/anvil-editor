param(
  [string]$Exe = "C:\Projects\c_projects\anvil-portable\anvil.exe",
  [string]$File = "C:\Users\Darius\Downloads\sqlite3.c",
  [int]$WarmupSeconds = 3,
  [int]$ScrollSeconds = 15,
  [int]$WheelEveryMs = 8,
  [int]$WheelDelta = -120,
  [switch]$UseGlobalMouseWheel,
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

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32Input {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
  public const int SW_RESTORE = 9;
  public const uint MOUSEEVENTF_WHEEL = 0x0800;
  public const uint WM_MOUSEWHEEL = 0x020A;
  public static UIntPtr MakeWheelWParam(int delta) { return (UIntPtr)(unchecked((uint)(delta << 16))); }
  public static IntPtr MakeLParam(int x, int y) { return (IntPtr)((y << 16) | (x & 0xffff)); }
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
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

  # The GUI exe can hand off to another Anvil process and exit cleanly, so
  # keep looking for the real window-owning process at the same exe path.
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

[Win32Input]::ShowWindow($hwnd, [Win32Input]::SW_RESTORE) | Out-Null
[Win32Input]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 250

$rect = New-Object Win32Input+RECT
[Win32Input]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$cx = [int](($rect.Left + $rect.Right) / 2)
$cy = [int](($rect.Top + $rect.Bottom) / 2)
[Win32Input]::SetCursorPos($cx, $cy) | Out-Null

Write-Host "Warmup ${WarmupSeconds}s..."
Start-Sleep -Seconds $WarmupSeconds

$scrollMode = if ($UseGlobalMouseWheel) { "global mouse_event" } else { "direct WM_MOUSEWHEEL to Anvil hwnd" }
Write-Host "Scrolling ${ScrollSeconds}s via ${scrollMode}: wheel delta $WheelDelta every ${WheelEveryMs}ms"
$end = (Get-Date).AddSeconds($ScrollSeconds)
$count = 0
while ((Get-Date) -lt $end) {
  try { $targetProcess.Refresh() } catch {}
  if ($targetProcess.HasExited) { break }
  if ($UseGlobalMouseWheel) {
    [Win32Input]::SetForegroundWindow($hwnd) | Out-Null
    [Win32Input]::SetCursorPos($cx, $cy) | Out-Null
    [Win32Input]::mouse_event([Win32Input]::MOUSEEVENTF_WHEEL, 0, 0, $WheelDelta, [UIntPtr]::Zero)
  } else {
    # Send directly to Anvil's SDL window. This avoids accidentally scrolling
    # whatever app has focus if Windows declines the foreground activation.
    [Win32Input]::PostMessage($hwnd, [Win32Input]::WM_MOUSEWHEEL, [Win32Input]::MakeWheelWParam($WheelDelta), [Win32Input]::MakeLParam($cx, $cy)) | Out-Null
  }
  $count++
  Start-Sleep -Milliseconds $WheelEveryMs
}
Write-Host "Sent $count wheel events"

Start-Sleep -Milliseconds 500
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
