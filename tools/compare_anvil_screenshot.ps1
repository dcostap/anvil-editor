param(
  [Parameter(Mandatory = $true)] [string]$Baseline,
  [Parameter(Mandatory = $true)] [string]$Current,
  [int]$PixelTolerance = 0,
  [long]$MaxMismatchedPixels = 0,
  [int]$IgnoreEdgePixels = 3,
  [string]$OutputJson = "",
  [switch]$AllowVisualMismatch
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $Baseline)) { throw "Baseline image not found: $Baseline" }
if (!(Test-Path -LiteralPath $Current)) { throw "Current image not found: $Current" }
$Baseline = (Resolve-Path -LiteralPath $Baseline).Path
$Current = (Resolve-Path -LiteralPath $Current).Path

if (-not ("AnvilScreenshotCompare" -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class AnvilScreenshotDiff {
  public bool SameSize;
  public int WidthA, HeightA, WidthB, HeightB;
  public long Pixels;
  public long MismatchedPixels;
  public long TotalChannelDifference;
  public int MaxChannelDifference;
}

public static class AnvilScreenshotCompare {
  public static AnvilScreenshotDiff CompareImages(string a, string b, int tolerance, int ignoreEdgePixels) {
    using (Bitmap ba = new Bitmap(a))
    using (Bitmap bb = new Bitmap(b)) {
      AnvilScreenshotDiff diff = new AnvilScreenshotDiff();
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

$imageDiff = [AnvilScreenshotCompare]::CompareImages($Baseline, $Current, $PixelTolerance, $IgnoreEdgePixels)
$visualPass = $imageDiff.SameSize -and $imageDiff.MismatchedPixels -le $MaxMismatchedPixels
$result = [ordered]@{
  baseline = $Baseline
  current = $Current
  visual_pass = $visualPass
  image_diff = [ordered]@{
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
  }
}

$json = $result | ConvertTo-Json -Depth 6
if ($OutputJson -ne "") { $json | Set-Content -LiteralPath $OutputJson -Encoding UTF8 }
Write-Output $json

if (!$visualPass -and !$AllowVisualMismatch) {
  throw "Screenshot differs from baseline: $($imageDiff.MismatchedPixels) mismatched pixels, max channel diff $($imageDiff.MaxChannelDifference). Current: $Current Baseline: $Baseline"
}
