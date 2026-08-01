param(
  [string]$Exe = "C:\Projects\c_projects\anvil-editor\build-windows-x86_64\src\anvil.exe",
  [string]$File = "C:\Projects\c_projects\anvil-editor\CONTEXT.md",
  [double]$MeasureSeconds = 5.0,
  [double]$SettleSeconds = 2.0,
  [string]$ArtifactsDir = (Join-Path $PSScriptRoot "perf-results\idle"),
  [double]$MaxIterationsPerSecond = 120.0,
  [double]$MaxIdleUiUpdateFraction = 0.10,
  [double]$MaxAwakeFraction = 0.20,
  [double]$MaxPendingEventFraction = 0.10,
  [double]$MinFocusedFraction = 0.90,
  [switch]$SoftwareRenderer
)

$ErrorActionPreference = "Stop"

$captureScript = Join-Path $PSScriptRoot "anvil_perf_capture_file.ps1"
$analyzer = Join-Path $PSScriptRoot "analyze_idle_perf.py"
$debugDataStart = Join-Path (Split-Path -Parent $Exe) "data\core\start.lua"
if (!(Test-Path -LiteralPath $debugDataStart)) {
  throw "Debug runtime data is missing beside $Exe. Run launch-anvil-debug.bat once to create its data junction."
}

$captureJson = & $captureScript `
  -Exe $Exe `
  -File $File `
  -MeasureSeconds $MeasureSeconds `
  -SettleSeconds $SettleSeconds `
  -ArtifactsDir $ArtifactsDir `
  -ForceRedraw:$false `
  -NoScreenshot `
  -NewInstance `
  -SoftwareRenderer:$SoftwareRenderer

$capture = $captureJson | ConvertFrom-Json
if (!$capture.frames_file) { throw "Idle capture did not report a frames CSV" }

Write-Host "Validating focused-idle capture: $($capture.frames_file)"
& python $analyzer $capture.frames_file `
  --max-iterations-per-second $MaxIterationsPerSecond `
  --max-idle-ui-update-fraction $MaxIdleUiUpdateFraction `
  --max-awake-fraction $MaxAwakeFraction `
  --max-pending-event-fraction $MaxPendingEventFraction `
  --min-focused-fraction $MinFocusedFraction
if ($LASTEXITCODE -ne 0) {
  throw "Focused-idle performance gate failed"
}
