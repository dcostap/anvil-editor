param(
  [Parameter(Mandatory = $true)]
  [string]$AnvilExe
)

$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

$testRoot = Join-Path $env:TEMP ("anvil-standalone-runtime-" + [guid]::NewGuid().ToString("N"))
$copyPath = Join-Path $testRoot "anvil.exe"
$runtimeRoot = Join-Path $testRoot "runtime"
$userRoot = Join-Path $testRoot "user"

$oldRuntimeRoot = $env:ANVIL_EMBEDDED_RUNTIME_ROOT
$oldUserDir = $env:ANVIL_USERDIR
$oldHeadless = $env:ANVIL_HEADLESS_TEST

try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  Copy-Item -LiteralPath $AnvilExe -Destination $copyPath

  $env:ANVIL_EMBEDDED_RUNTIME_ROOT = $runtimeRoot
  $env:ANVIL_USERDIR = $userRoot
  $env:ANVIL_HEADLESS_TEST = "1"

  $helpOutput = (& $copyPath --help 2>&1 | Out-String)
  Assert-True ($LASTEXITCODE -eq 0) "The standalone executable crashed while printing command-line help."
  Assert-True ($helpOutput.Contains("--new-window")) "Command-line help omitted the long-only new-window option."

  $first = Start-Process -FilePath $copyPath -ArgumentList "--version" -PassThru
  $parallel = Start-Process -FilePath $copyPath -ArgumentList "--version" -PassThru
  $first.WaitForExit()
  $parallel.WaitForExit()
  Assert-True ($first.ExitCode -eq 0) "The copied executable did not start without an adjacent data directory."
  Assert-True ($parallel.ExitCode -eq 0) "A concurrent first launch did not share runtime extraction safely."
  Assert-True (-not (Test-Path (Join-Path $testRoot "data"))) "The executable created an adjacent data directory."

  $startFile = Get-ChildItem -LiteralPath $runtimeRoot -Filter "start.lua" -File -Recurse |
    Where-Object { $_.FullName -match "[\\/]data[\\/]core[\\/]start\.lua$" } |
    Select-Object -First 1
  Assert-True ($null -ne $startFile) "The embedded runtime did not extract data/core/start.lua."

  $ripgrep = Get-ChildItem -LiteralPath $runtimeRoot -Filter "rg.exe" -File -Recurse |
    Where-Object { $_.FullName -match "[\\/]data[\\/]plugins[\\/]fuzzy_searcher[\\/]rg\.exe$" } |
    Select-Object -First 1
  Assert-True ($null -ne $ripgrep) "The embedded runtime did not extract its ripgrep helper."
  & $ripgrep.FullName --version | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "The extracted ripgrep helper did not run."

  $marker = Get-ChildItem -LiteralPath $runtimeRoot -Filter ".complete" -File -Recurse |
    Select-Object -First 1
  Assert-True ($null -ne $marker) "The embedded runtime did not write its completion marker."
  $markerWriteTime = $marker.LastWriteTimeUtc

  Start-Sleep -Milliseconds 50
  $second = Start-Process -FilePath $copyPath -ArgumentList "--version" -PassThru -Wait
  Assert-True ($second.ExitCode -eq 0) "The copied executable did not reuse its extracted runtime."
  $marker.Refresh()
  Assert-True ($marker.LastWriteTimeUtc -eq $markerWriteTime) "The second launch extracted the same runtime again."

  Remove-Item -LiteralPath $startFile.FullName -Force
  $staleStaging = $marker.Directory.FullName + ".tmp"
  New-Item -ItemType Directory -Path $staleStaging | Out-Null
  Set-Content -LiteralPath (Join-Path $staleStaging "stale.txt") -Value "stale"
  Start-Sleep -Milliseconds 50
  $repair = Start-Process -FilePath $copyPath -ArgumentList "--version" -PassThru -Wait
  Assert-True ($repair.ExitCode -eq 0) "The copied executable did not repair an incomplete runtime."
  Assert-True (Test-Path $startFile.FullName) "The repaired runtime is still missing data/core/start.lua."
  Assert-True (-not (Test-Path $staleStaging)) "The runtime repair left its stale staging directory."

  Write-Host "Standalone runtime smoke test passed."
}
finally {
  $env:ANVIL_EMBEDDED_RUNTIME_ROOT = $oldRuntimeRoot
  $env:ANVIL_USERDIR = $oldUserDir
  $env:ANVIL_HEADLESS_TEST = $oldHeadless
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
