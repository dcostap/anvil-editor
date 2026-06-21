param(
  [string]$Exe = "C:\Projects\c_projects\anvil-portable\anvil.exe",
  [string]$File = "C:\Users\Darius\Downloads\test-big-repository\test.txt",
  [double]$WarmupSeconds = 0.75,
  [double]$MeasureSeconds = 2.0,
  [double]$SettleSeconds = 0.25,
  [int]$StartLine = 1,
  [int]$WindowX = 80,
  [int]$WindowY = 60,
  [int]$WindowWidth = 1400,
  [int]$WindowHeight = 900,
  [int]$ScreenshotDelayMs = 500,
  [int]$ReadyDelayMs = 1500,
  [string]$DisablePlugins = "",
  [string]$Metric = "total_ms",
  [string]$ArtifactsDir = (Join-Path $PSScriptRoot "perf-results\whitespace"),
  [string]$Baseline = (Join-Path $PSScriptRoot "baselines\whitespace_perf_baseline.png"),
  [string]$BestFile = (Join-Path $PSScriptRoot "baselines\whitespace_perf_best.json"),
  [int]$PixelTolerance = 0,
  [long]$MaxMismatchedPixels = 0,
  [int]$IgnoreEdgePixels = 3,
  [switch]$UpdateBaseline,
  [switch]$RequireBaseline,
  [switch]$AllowVisualMismatch,
  [switch]$SoftwareRenderer,
  [switch]$KeepOpen,
  [switch]$NoKillExisting,
  [switch]$NoAnalyze
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $Exe)) { throw "Anvil exe not found: $Exe" }
if (!(Test-Path -LiteralPath $File)) { throw "Test file not found: $File" }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$File = (Resolve-Path -LiteralPath $File).Path
New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Baseline) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BestFile) | Out-Null

$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$runDir = Join-Path $ArtifactsDir $runId
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ResultFile = Join-Path $runDir "probe_result.txt"
$GoFile = Join-Path $runDir "go.signal"
$ControlFile = Join-Path (Join-Path (Split-Path -Parent $Exe) "user") "whitespace_perf_probe.cfg"
$FrameStatsFile = Join-Path $runDir "frame_pacing.csv"
$D3DStatsFile = Join-Path $runDir "d3d11.csv"
$Screenshot = Join-Path $runDir "screenshot.png"
$RunSummary = Join-Path $runDir "summary.json"

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

function Get-Percentile([double[]]$Values, [double]$Q) {
  if (!$Values -or $Values.Count -eq 0) { return 0.0 }
  $sorted = @($Values | Sort-Object)
  $index = [Math]::Min($sorted.Count - 1, [Math]::Max(0, [int][Math]::Floor(($sorted.Count - 1) * $Q)))
  return [double]$sorted[$index]
}

function Get-ColumnStats($Rows, [string]$Name) {
  $values = @($Rows | ForEach-Object {
    $value = $_.$Name
    if ($null -ne $value -and $value -ne "") { [double]$value }
  })
  if ($values.Count -eq 0) {
    return [ordered]@{ avg = 0.0; p50 = 0.0; p90 = 0.0; p95 = 0.0; max = 0.0 }
  }
  $sum = 0.0
  foreach ($v in $values) { $sum += $v }
  return [ordered]@{
    avg = $sum / $values.Count
    p50 = Get-Percentile $values 0.50
    p90 = Get-Percentile $values 0.90
    p95 = Get-Percentile $values 0.95
    max = [double](@($values | Measure-Object -Maximum).Maximum)
  }
}

function Analyze-FrameStats([string]$Csv, [double]$StartTime, [double]$EndTime) {
  if (!(Test-Path -LiteralPath $Csv)) { throw "Frame stats missing: $Csv" }
  $rows = @(Import-Csv -LiteralPath $Csv | Where-Object {
    $_.did_redraw -eq "1" -and [double]$_.time -ge $StartTime -and [double]$_.time -le $EndTime
  })
  if ($rows.Count -eq 0) { throw "No redraw rows found in measured interval $StartTime..$EndTime" }

  $metrics = [ordered]@{}
  foreach ($name in @(
    "total_ms", "frame_time_ms", "draw_emit_ms", "renderer_end_ms", "present_ms",
    "docview_draw_ms", "docview_body_ms", "docview_text_ms", "docview_renderer_draw_text_ms",
    "docview_highlighter_get_line_ms", "docview_token_loop_ms", "rencache_draw_text_ms", "rencache_draw_text_width_ms",
    "draw_calls", "quad_instances", "rencache_commands", "rencache_text_commands", "rencache_rect_commands",
    "docview_visible_lines", "docview_text_lines", "docview_tokens", "docview_draw_text_calls"
  )) {
    $metrics[$name] = Get-ColumnStats $rows $name
  }

  return [ordered]@{
    measured_rows = $rows.Count
    first_time = [double]$rows[0].time
    last_time = [double]$rows[$rows.Count - 1].time
    metrics = $metrics
  }
}

if (-not ("AnvilWhitespacePerfHarness" -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class AnvilImageDiff {
  public bool SameSize;
  public int WidthA, HeightA, WidthB, HeightB;
  public long Pixels;
  public long MismatchedPixels;
  public long TotalChannelDifference;
  public int MaxChannelDifference;
}

public static class AnvilWhitespacePerfHarness {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  public const int SW_RESTORE = 9;
  public const byte VK_ESCAPE = 0x1B;
  public const uint KEYEVENTF_KEYUP = 0x0002;
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  public const uint SWP_NOZORDER = 0x0004;
  public const uint SWP_NOACTIVATE = 0x0010;

  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public static void PlaceWindow(IntPtr hWnd, int x, int y, int w, int h) {
    ShowWindow(hWnd, SW_RESTORE);
    SetWindowPos(hWnd, IntPtr.Zero, x, y, w, h, SWP_NOZORDER);
    SetForegroundWindow(hWnd);
  }

  public static void PressEscape() {
    keybd_event(VK_ESCAPE, 0, 0, UIntPtr.Zero);
    keybd_event(VK_ESCAPE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
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

  public static AnvilImageDiff CompareImages(string a, string b, int tolerance, int ignoreEdgePixels) {
    using (Bitmap ba = new Bitmap(a))
    using (Bitmap bb = new Bitmap(b)) {
      AnvilImageDiff diff = new AnvilImageDiff();
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
        int ignoreTopRightWidth = Math.Min(420, ba.Width);
        int ignoreTopRightHeight = Math.Min(42, ba.Height);
        int ignoreTopRightX = ba.Width - ignoreTopRightWidth;
        diff.Pixels = 0;
        for (int y = y0; y < y1; y++) {
          int row = y * Math.Abs(da.Stride);
          for (int x = x0; x < x1; x++) {
            if (y < ignoreTopRightHeight && x >= ignoreTopRightX) continue;
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

if (!$NoKillExisting) {
  Get-Process -Name "anvil" -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $Exe } catch { $false }
  } | ForEach-Object {
    Write-Host "Stopping existing Anvil pid $($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 500
}

Remove-Item -LiteralPath $ResultFile, $GoFile, $FrameStatsFile, $D3DStatsFile -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ControlFile) | Out-Null
@(
  "enabled=1",
  "file=$File",
  "seconds=$MeasureSeconds",
  "warmup=$WarmupSeconds",
  "settle=$SettleSeconds",
  "start_line=$StartLine",
  "result_file=$ResultFile",
  "go_file=$GoFile"
) | Set-Content -LiteralPath $ControlFile -Encoding ASCII

$env:ANVIL_WHITESPACE_PERF_TEST = "1"
$env:ANVIL_WHITESPACE_PERF_FILE = $File
$env:ANVIL_WHITESPACE_PERF_SECONDS = "$MeasureSeconds"
$env:ANVIL_WHITESPACE_PERF_WARMUP = "$WarmupSeconds"
$env:ANVIL_WHITESPACE_PERF_SETTLE = "$SettleSeconds"
$env:ANVIL_WHITESPACE_PERF_START_LINE = "$StartLine"
$env:ANVIL_WHITESPACE_PERF_RESULT_FILE = $ResultFile
$env:ANVIL_WHITESPACE_PERF_GO_FILE = $GoFile
$env:ANVIL_TEST_DISABLE_PLUGINS = $DisablePlugins
$env:ANVIL_RAD_PACING = "1"
$env:ANVIL_FRAME_PACING_STATS = "1"
$env:ANVIL_FRAME_PACING_STATS_FILE = $FrameStatsFile
Remove-Item Env:\ANVIL_FRAME_PACING_STATS_FLUSH -ErrorAction SilentlyContinue
$env:ANVIL_D3D11_STATS = "1"
$env:ANVIL_D3D11_STATS_FILE = $D3DStatsFile
Remove-Item Env:\ANVIL_D3D11_STATS_FLUSH -ErrorAction SilentlyContinue
$env:ANVIL_DOCVIEW_STATS = "1"
if ($SoftwareRenderer) { $env:ANVIL_RENDERER = "software" } else { Remove-Item Env:\ANVIL_RENDERER -ErrorAction SilentlyContinue }

Write-Host "Launching $Exe"
Write-Host "File: $File"
Write-Host "Run dir: $runDir"
$p = Start-Process -FilePath $Exe -ArgumentList @($File) -PassThru
Write-Host "Started pid $($p.Id)"

$deadline = (Get-Date).AddSeconds(20)
$hwnd = [IntPtr]::Zero
$targetProcess = $p
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
[AnvilWhitespacePerfHarness]::PlaceWindow($hwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight)
Start-Sleep -Milliseconds 250
[AnvilWhitespacePerfHarness]::PlaceWindow($hwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight)
Start-Sleep -Milliseconds 250
Write-Host "Signalling probe"
Set-Content -LiteralPath $GoFile -Value "go" -Encoding ASCII

$timeout = [Math]::Max(30, [int]($WarmupSeconds + $MeasureSeconds + $SettleSeconds + 25))
$deadline = (Get-Date).AddSeconds($timeout)
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $ResultFile) { break }
  Start-Sleep -Milliseconds 100
}
if (!(Test-Path -LiteralPath $ResultFile)) { throw "Timed out waiting for result file: $ResultFile" }

$probeResult = Read-KeyValueFile $ResultFile
$startTime = [double]$probeResult.start_time
$endTime = [double]$probeResult.end_time
$analysis = Analyze-FrameStats $FrameStatsFile $startTime $endTime
if (!$analysis.metrics.Contains($Metric)) { throw "Unknown metric '$Metric' in frame stats analysis" }
$score = [double]$analysis.metrics[$Metric].avg

Start-Sleep -Milliseconds $ScreenshotDelayMs
[AnvilWhitespacePerfHarness]::PressEscape()
Start-Sleep -Milliseconds 100
[AnvilWhitespacePerfHarness]::PlaceWindow($hwnd, $WindowX, $WindowY, $WindowWidth, $WindowHeight)
Start-Sleep -Milliseconds 100
[AnvilWhitespacePerfHarness]::CaptureWindow($hwnd, $Screenshot)

$baselineStatus = "compared"
$visualPass = $true
$imageDiff = $null
if ($UpdateBaseline -or !(Test-Path -LiteralPath $Baseline)) {
  if ($RequireBaseline -and !(Test-Path -LiteralPath $Baseline) -and !$UpdateBaseline) {
    throw "Baseline missing: $Baseline"
  }
  Copy-Item -LiteralPath $Screenshot -Destination $Baseline -Force
  $baselineStatus = if ($UpdateBaseline) { "updated" } else { "created" }
} else {
  $imageDiff = [AnvilWhitespacePerfHarness]::CompareImages($Baseline, $Screenshot, $PixelTolerance, $IgnoreEdgePixels)
  $visualPass = $imageDiff.SameSize -and $imageDiff.MismatchedPixels -le $MaxMismatchedPixels
}

$bestBefore = $null
if (Test-Path -LiteralPath $BestFile) {
  try { $bestBefore = Get-Content -LiteralPath $BestFile -Raw | ConvertFrom-Json } catch { $bestBefore = $null }
}
$bestUpdated = $false
if ($visualPass) {
  if ($null -eq $bestBefore -or $score -lt [double]$bestBefore.score) {
    $bestUpdated = $true
  }
}

$result = [ordered]@{
  run_id = $runId
  run_dir = $runDir
  file = $File
  screenshot = $Screenshot
  baseline = $Baseline
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
  metric = $Metric
  score = $score
  best_before = if ($bestBefore) { [ordered]@{ run_id = $bestBefore.run_id; score = [double]$bestBefore.score; run_dir = $bestBefore.run_dir } } else { $null }
  best_updated = $bestUpdated
  measured_rows = $analysis.measured_rows
  measured_start_time = $startTime
  measured_end_time = $endTime
  metrics = $analysis.metrics
  frame_stats = $FrameStatsFile
  d3d_stats = $D3DStatsFile
  result_file = $ResultFile
}

($result | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $RunSummary -Encoding UTF8
if ($bestUpdated) {
  ($result | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $BestFile -Encoding UTF8
}

Write-Host ("Score {0} avg: {1:N3} ms over {2} redraw frames" -f $Metric, $score, $analysis.measured_rows)
if ($result.best_before) {
  $delta = $score - [double]$result.best_before.score
  Write-Host ("Best before: {0:N3} ms ({1:+0.000;-0.000;0.000} ms vs best)" -f [double]$result.best_before.score, $delta)
}
if ($bestUpdated) { Write-Host "New best recorded: $BestFile" }
Write-Host "Screenshot: $Screenshot"
Write-Host "Baseline:   $Baseline ($baselineStatus)"
if ($imageDiff) { Write-Host ("Visual diff: {0} mismatched pixels, max channel diff {1}" -f $imageDiff.MismatchedPixels, $imageDiff.MaxChannelDifference) }
Write-Host "Summary:    $RunSummary"

if (!$KeepOpen) {
  $target = Get-AnvilTestProcess
  if ($target -and !$target.HasExited) {
    Write-Host "Stopping Anvil pid $($target.Id)"
    Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
  }
}

if (!$visualPass -and !$AllowVisualMismatch) {
  throw "Screenshot differs from baseline beyond tolerance. Current: $Screenshot Baseline: $Baseline"
}

if (!$NoAnalyze) {
  $analyzer = Join-Path $PSScriptRoot "analyze_frame_pacing_stats.py"
  if (Test-Path -LiteralPath $analyzer) {
    python $analyzer --frame $FrameStatsFile --d3d $D3DStatsFile
  }
}

Write-Output ($result | ConvertTo-Json -Depth 12)
