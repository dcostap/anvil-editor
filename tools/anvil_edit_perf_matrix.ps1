param(
  [string]$Exe = "C:\Projects\c_projects\anvil-portable\anvil.exe",
  [string]$File = "C:\Users\Dario Costa\Desktop\projects\castrosua_legacy\test_project\AGENTS.md",
  [int]$WarmupSeconds = 1,
  [int]$StressSeconds = 15,
  [int]$OpsPerSecond = 30,
  [string]$DisablePlugins = "drawwhitespace,indent_guides,gitdiff_highlight,performance_hud,editor_wallpaper",
  [string]$OutCsv = "$env:TEMP\anvil_edit_perf_matrix.csv"
)

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "anvil_edit_perf_test.ps1"
if (!(Test-Path -LiteralPath $runner)) { throw "Missing runner: $runner" }

$cases = @(
  @{ name = "d3d11_baseline"; software = $false; disabled = "" },
  @{ name = "d3d11_plugins_disabled"; software = $false; disabled = $DisablePlugins },
  @{ name = "software_baseline"; software = $true; disabled = "" },
  @{ name = "software_plugins_disabled"; software = $true; disabled = $DisablePlugins }
)

function Read-Metric([string]$Path, [string]$Prefix) {
  if (!(Test-Path -LiteralPath $Path)) { return "" }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line.StartsWith($Prefix)) { return $line.Substring($Prefix.Length).Trim() }
  }
  return ""
}

function Count-SlowRows([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) { return 0 }
  $lines = Get-Content -LiteralPath $Path
  $start = [Array]::IndexOf($lines, "Slow redraw frames (top by total_ms; thresholds total>25ms/frame>20ms/present>18ms):")
  if ($start -lt 0) { return 0 }
  $count = 0
  for ($i = $start + 2; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -eq "") { break }
    $count++
  }
  return $count
}

$rows = @()
foreach ($case in $cases) {
  Write-Host "=== $($case.name) ==="
  $args = @(
    "-Exe", $Exe,
    "-File", $File,
    "-WarmupSeconds", "$WarmupSeconds",
    "-StressSeconds", "$StressSeconds",
    "-OpsPerSecond", "$OpsPerSecond",
    "-NoAnalyze"
  )
  if ($case.software) { $args += "-SoftwareRenderer" }
  if ($case.disabled -ne "") { $args += @("-DisablePlugins", $case.disabled) }
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner @args
  $summary = ($output | Where-Object { $_ -match "anvil_perf_.*_summary\.txt" } | Select-Object -Last 1).Trim()
  Write-Host "Summary: $summary"
  $rows += [PSCustomObject]@{
    case = $case.name
    summary = $summary
    redraw_frames = Read-Metric $summary "Redraw frames:"
    active_fps = Read-Metric $summary "Active-cadence redraw FPS (intervals <=20ms):"
    over_budget = Read-Metric $summary "Over-budget redraw frames:"
    redraw_gaps = Read-Metric $summary "Redraw gaps >20ms:"
    slow_rows = Count-SlowRows $summary
  }
}

$rows | Export-Csv -NoTypeInformation -LiteralPath $OutCsv
Write-Host "Matrix CSV: $OutCsv"
$rows | Format-Table -AutoSize
