# Closes the dev Anvil editor and leaves Terminal Sessions running.
# Then moves the files that running terminal hosts lock out of the install path.
param([Parameter(Mandatory = $true)][string]$AppRoot, [int]$TimeoutSeconds = 120)
$ErrorActionPreference = 'Stop'
$AppRoot = [IO.Path]::GetFullPath($AppRoot)
# C:\Projects can be a link to D:\Projects, so compare paths without the drive.
$tail = (Join-Path $AppRoot 'anvil.exe').Substring(2)

function Get-Editors {
  @(Get-CimInstance Win32_Process -Filter "Name = 'anvil.exe'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.Substring(2) -eq $tail -and
      $_.CommandLine -notmatch '--terminal-session'
  })
}

$editors = Get-Editors
if ($editors.Count) {
  Write-Host 'Saving Workspaces and detaching Terminal Sessions...'
  # The shell accepts this request only from its own executable path.
  $request = Start-Process -FilePath $editors[0].ExecutablePath -ArgumentList '--prepare-update' -PassThru -Wait
  if ($request.ExitCode -ne 0) { throw 'Anvil did not accept the update request. No process was stopped.' }
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ((Get-Editors).Count) {
    if ([DateTime]::UtcNow -ge $deadline) {
      throw 'Anvil did not close. Check its dialogs, then retry. Terminal Sessions still run.'
    }
    Start-Sleep -Milliseconds 100
  }
}

# Windows lets a running image move but not be replaced. Running hosts keep
# their moved files. Remove each old copy that no host uses any more.
$retired = Join-Path $AppRoot 'retired'
$target = Join-Path $retired ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))
foreach ($relative in 'anvil.exe', 'data\conpty\conpty.dll', 'data\conpty\OpenConsole.exe') {
  $from = Join-Path $AppRoot $relative
  if (-not (Test-Path -LiteralPath $from)) { continue }
  $to = Join-Path $target $relative
  [IO.Directory]::CreateDirectory((Split-Path $to)) | Out-Null
  [IO.File]::Move($from, $to)
}
if (Test-Path -LiteralPath $retired) {
  foreach ($old in Get-ChildItem -LiteralPath $retired -Directory) {
    Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
}
