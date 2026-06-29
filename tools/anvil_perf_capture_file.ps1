param(
  [string]$Exe = "C:\Projects\c_projects\anvil-portable\anvil.exe",
  [string]$File = "C:\Users\Darius\Downloads\odin_book_1_10_annotated_widgets.html",
  [double]$MeasureSeconds = 2.0,
  [double]$SettleSeconds = 0.25,
  [int]$StartLine = 1,
  [int]$WindowX = 80,
  [int]$WindowY = 60,
  [int]$WindowWidth = 1400,
  [int]$WindowHeight = 900,
  [int]$ReadyDelayMs = 1500,
  [int]$ScreenshotDelayMs = 500,
  [string]$DisablePlugins = "",
  [string]$ArtifactsDir = (Join-Path $PSScriptRoot "perf-results\perf-capture"),
  [string]$Baseline = (Join-Path $PSScriptRoot "baselines\perf_capture_odin_book.png"),
  [int]$PixelTolerance = 0,
  [long]$MaxMismatchedPixels = 0,
  [int]$IgnoreEdgePixels = 3,
  [bool]$ForceRedraw = $true,
  [switch]$UpdateBaseline,
  [switch]$RequireBaseline,
  [switch]$AllowVisualMismatch,
  [switch]$NoScreenshot,
  [switch]$SoftwareRenderer,
  [switch]$KeepOpen,
  [switch]$NoKillExisting
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $Exe)) { throw "Anvil exe not found: $Exe" }
if (!(Test-Path -LiteralPath $File)) { throw "Test file not found: $File" }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$File = (Resolve-Path -LiteralPath $File).Path
New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null
if (!$NoScreenshot) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Baseline) | Out-Null }

$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$runDir = Join-Path $ArtifactsDir $runId
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ResultFile = Join-Path $runDir "perf_capture_result.txt"
$GoFile = Join-Path $runDir "go.signal"
$RunSummary = Join-Path $runDir "summary.json"
$Screenshot = Join-Path $runDir "screenshot.png"
$ControlFile = Join-Path (Join-Path (Split-Path -Parent $Exe) "user") "perf_capture.cfg"
$targetProcess = $null
$visualPass = $true

function Get-AnvilTestProcess {
  Get-Process -Name "anvil" -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $Exe } catch { $false }
  } | Sort-Object StartTime -Descending | Select-Object -First 1
}

function Read-KeyValueFile([string]$Path) {
  $map = @{}
  if (!(Test-Path -LiteralPath $Path)) { return $map }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^([^=]+)=(.*)$') { $map[$matches[1]] = $matches[2] }
  }
  return $map
}

if (-not ("AnvilPerfCaptureHarness" -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class AnvilPerfCaptureImageDiff {
  public bool SameSize;
  public int WidthA, HeightA, WidthB, HeightB;
  public long Pixels;
  public long MismatchedPixels;
  public long TotalChannelDifference;
  public int MaxChannelDifference;
}

public static class AnvilPerfCaptureHarness {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  public const int SW_RESTORE = 9;
  public const uint SWP_NOZORDER = 0x0004;

  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public static void PlaceWindow(IntPtr hWnd, int x, int y, int w, int h) {
    ShowWindow(hWnd, SW_RESTORE);
    SetWindowPos(hWnd, IntPtr.Zero, x, y, w, h, SWP_NOZORDER);
    SetForegroundWindow(hWnd);
  }

  public static void CaptureWindow(IntPtr hWnd, string path) {
    RECT r;
    if (!GetWindowRect(hWnd, out r)) throw new InvalidOperationException("GetWindowRect failed");
    int w = Math.Max(1, r.Right - r.Left);
    int h = Math.Max(1, r.Bottom - r.Top);
    using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
      }
      bmp.Save(path, ImageFormat.Png);
    }
  }

  public static AnvilPerfCaptureImageDiff CompareImages(string a, string b, int tolerance, int ignoreEdgePixels) {
    using (Bitmap ba = new Bitmap(a))
    using (Bitmap bb = new Bitmap(b)) {
      AnvilPerfCaptureImageDiff diff = new AnvilPerfCaptureImageDiff();
      diff.WidthA = ba.Width; diff.HeightA = ba.Height;
      diff.WidthB = bb.Width; diff.HeightB = bb.Height;
      diff.SameSize = ba.Width == bb.Width && ba.Height == bb.Height;
      if (!diff.SameSize) return diff;
      Rectangle rect = new Rectangle(0, 0, ba.Width, ba.Height);
      BitmapData da = ba.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      BitmapData db = bb.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      try {
        int bytes = Math.Abs(da.Stride) * da.Height;
        byte[] pa = new byte[bytes];
        byte[] pb = new byte[bytes];
        Marshal.Copy(da.Scan0, pa, 0, bytes);
        Marshal.Copy(db.Scan0, pb, 0, bytes);
        int edge = Math.Max(0, ignoreEdgePixels);
        int x0 = Math.Min(edge, ba.Width);
        int y0 = Math.Min(edge, ba.Height);
        int x1 = Math.Max(x0, ba.Width - edge);
        int y1 = Math.Max(y0, ba.Height - edge);
        diff.Pixels = 0;
        for (int y = y0; y < y1; y++) {
          int row = y * Math.Abs(da.Stride);
          for (int x = x0; x < x1; x++) {
            diff.Pixels++;
            int i = row + x * 4;
            int d0 = Math.Abs(pa[i] - pb[i]);
            int d1 = Math.Abs(pa[i + 1] - pb[i + 1]);
            int d2 = Math.Abs(pa[i + 2] - pb[i + 2]);
            int max = Math.Max(d0, Math.Max(d1, d2));
            if (max > diff.MaxChannelDifference) diff.MaxChannelDifference = max;
            diff.TotalChannelDifference += d0 + d1 + d2;
            if (max > tolerance) diff.MismatchedPixels++;
          }
        }
      } finally {
        ba.UnlockBits(da);
        bb.UnlockBits(db);
      }
      return diff;
    }
  }
}
"@
}

try {
  if (!$NoKillExisting) {
    Get-Process -Name "anvil" -ErrorAction SilentlyContinue | Where-Object {
      try { $_.Path -eq $Exe } catch { $false }
    } | ForEach-Object {
      Write-Host "Stopping existing Anvil pid $($_.Id)"
      Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
  }

  Remove-Item -LiteralPath $ResultFile, $GoFile, $Screenshot -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ControlFile) | Out-Null
  $forceRedrawValue = if ($ForceRedraw) { "1" } else { "0" }
  @(
    "enabled=1",
    "file=$File",
    "seconds=$MeasureSeconds",
    "settle=$SettleSeconds",
    "start_line=$StartLine",
    "result_file=$ResultFile",
    "go_file=$GoFile",
    "force_redraw=$forceRedrawValue"
  ) | Set-Content -LiteralPath $ControlFile -Encoding ASCII

  $env:ANVIL_PERF_CAPTURE = "1"
  $env:ANVIL_PERF_CAPTURE_FILE = $File
  $env:ANVIL_PERF_CAPTURE_SECONDS = "$MeasureSeconds"
  $env:ANVIL_PERF_CAPTURE_SETTLE = "$SettleSeconds"
  $env:ANVIL_PERF_CAPTURE_START_LINE = "$StartLine"
  $env:ANVIL_PERF_CAPTURE_RESULT_FILE = $ResultFile
  $env:ANVIL_PERF_CAPTURE_GO_FILE = $GoFile
  $env:ANVIL_PERF_CAPTURE_FORCE_REDRAW = $forceRedrawValue
  $env:ANVIL_PERF_OUTPUT_DIR = $runDir
  $env:ANVIL_TEST_DISABLE_PLUGINS = $DisablePlugins
  if ($SoftwareRenderer) { $env:ANVIL_RENDERER = "software" } else { Remove-Item Env:\ANVIL_RENDERER -ErrorAction SilentlyContinue }

  Write-Host "Launching $Exe"
  Write-Host "File: $File"
  Write-Host "Run dir: $runDir"
  $p = Start-Process -FilePath $Exe -ArgumentList @($File) -WorkingDirectory (Split-Path -Parent $Exe) -PassThru
  $targetProcess = $p
  Write-Host "Started pid $($p.Id)"

  $deadline = (Get-Date).AddSeconds(20)
  $hwnd = [IntPtr]::Zero
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    try { $targetProcess.Refresh() } catch {}
    $currentHwnd = if ($targetProcess.HasExited) { [IntPtr]::Zero } else { [IntPtr]$targetProcess.MainWindowHandle }
    if ($targetProcess.HasExited -or $currentHwnd -eq [IntPtr]::Zero) {
      $found = Get-AnvilTestProcess
      if ($found) { $targetProcess = $found }
      $currentHwnd = if ($targetProcess.HasExited) { [IntPtr]::Zero } else { [IntPtr]$targetProcess.MainWindowHandle }
    }
    if (!$targetProcess.HasExited -and $currentHwnd -ne [IntPtr]::Zero) {
      $hwnd = $currentHwnd
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "Timed out waiting for Anvil main window" }
  Write-Host "Window hwnd $hwnd"

  Start-Sleep -Milliseconds $ReadyDelayMs
  Write-Host "Placing window"
  [AnvilPerfCaptureHarness]::PlaceWindow($hwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight)
  Start-Sleep -Milliseconds 250
  [AnvilPerfCaptureHarness]::PlaceWindow($hwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight)
  Start-Sleep -Milliseconds 250
  Write-Host "Signalling capture"
  Set-Content -LiteralPath $GoFile -Value "go" -Encoding ASCII

  $timeout = [Math]::Max(30, [int]($MeasureSeconds + $SettleSeconds + 25))
  $deadline = (Get-Date).AddSeconds($timeout)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $ResultFile) { break }
    Start-Sleep -Milliseconds 100
  }
  if (!(Test-Path -LiteralPath $ResultFile)) { throw "Timed out waiting for result file: $ResultFile" }

  $captureResult = Read-KeyValueFile $ResultFile
  if ($captureResult.done -ne "1") {
    $errorText = if ($captureResult.error) { $captureResult.error } else { "unknown capture failure" }
    throw "Perf capture failed: $errorText"
  }

  $baselineStatus = "skipped"
  $imageDiff = $null
  if (!$NoScreenshot) {
    Start-Sleep -Milliseconds $ScreenshotDelayMs
    [AnvilPerfCaptureHarness]::PlaceWindow($hwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight)
    Start-Sleep -Milliseconds 100
    [AnvilPerfCaptureHarness]::CaptureWindow($hwnd, $Screenshot)

    if ($UpdateBaseline -or !(Test-Path -LiteralPath $Baseline)) {
      if ($RequireBaseline -and !(Test-Path -LiteralPath $Baseline) -and !$UpdateBaseline) {
        throw "Baseline missing: $Baseline"
      }
      Copy-Item -LiteralPath $Screenshot -Destination $Baseline -Force
      $baselineStatus = if ($UpdateBaseline) { "updated" } else { "created" }
    } else {
      $imageDiff = [AnvilPerfCaptureHarness]::CompareImages($Baseline, $Screenshot, $PixelTolerance, $IgnoreEdgePixels)
      $visualPass = $imageDiff.SameSize -and $imageDiff.MismatchedPixels -le $MaxMismatchedPixels
      $baselineStatus = "compared"
    }
  }

  $result = [ordered]@{
    run_id = $runId
    run_dir = $runDir
    file = $File
    measured_start_time = [double]$captureResult.start_time
    measured_end_time = [double]$captureResult.end_time
    duration = [double]$captureResult.duration
    force_redraw = $ForceRedraw
    screenshot = if ($NoScreenshot) { $null } else { $Screenshot }
    baseline = if ($NoScreenshot) { $null } else { $Baseline }
    baseline_status = $baselineStatus
    visual_pass = $visualPass
    image_diff = if ($imageDiff) { [ordered]@{
      same_size = $imageDiff.SameSize
      width_a = $imageDiff.WidthA; height_a = $imageDiff.HeightA
      width_b = $imageDiff.WidthB; height_b = $imageDiff.HeightB
      pixels = $imageDiff.Pixels
      mismatched_pixels = $imageDiff.MismatchedPixels
      max_channel_difference = $imageDiff.MaxChannelDifference
      total_channel_difference = $imageDiff.TotalChannelDifference
      pixel_tolerance = $PixelTolerance
      max_mismatched_pixels = $MaxMismatchedPixels
      ignore_edge_pixels = $IgnoreEdgePixels
    } } else { $null }
    result_file = $ResultFile
    summary_file = $captureResult.summary_file
    frames_file = $captureResult.frames_file
    lua_samples_file = $captureResult.lua_samples_file
    api_calls_file = $captureResult.api_calls_file
    details_file = $captureResult.details_file
  }

  ($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $RunSummary -Encoding UTF8
  Write-Host "Performance summary: $($result.summary_file)"
  Write-Host "Frame CSV:           $($result.frames_file)"
  if (!$NoScreenshot) {
    Write-Host "Screenshot:          $Screenshot"
    Write-Host "Baseline:            $Baseline ($baselineStatus)"
    if ($imageDiff) { Write-Host ("Visual diff:        {0} mismatched pixels, max channel diff {1}" -f $imageDiff.MismatchedPixels, $imageDiff.MaxChannelDifference) }
  }
  Write-Host "Run summary:         $RunSummary"

  if (!$KeepOpen -and !$NoKillExisting) {
    $target = Get-AnvilTestProcess
    if ($target -and !$target.HasExited) {
      Write-Host "Stopping Anvil pid $($target.Id)"
      Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Output ($result | ConvertTo-Json -Depth 8)

  if (!$visualPass -and !$AllowVisualMismatch) {
    throw "Screenshot differs from baseline beyond tolerance. Current: $Screenshot Baseline: $Baseline"
  }
} finally {
  if (Test-Path -LiteralPath (Split-Path -Parent $ControlFile)) {
    @("enabled=0") | Set-Content -LiteralPath $ControlFile -Encoding ASCII
  }
}
