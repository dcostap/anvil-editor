# Release updates run outside Anvil's process group. A failed download never closes the editor.
param([ValidateSet('Launch', 'Apply')][string]$Mode = 'Launch', [string]$RequestFile)
$ErrorActionPreference = 'Stop'
# A Terminal can pass PowerShell 7's module path to Windows PowerShell 5.1.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Force

function Set-AnvilUpdateStatus($request, [string]$state, [string]$message) {
  $status = @{ state = $state; message = $message; version = $request.version } | ConvertTo-Json -Compress
  $temporary = $request.status + '.tmp'
  [IO.File]::WriteAllText($temporary, $status, [Text.UTF8Encoding]::new($false))
  if ([IO.File]::Exists($request.status)) { [IO.File]::Replace($temporary, $request.status, [NullString]::Value) }
  else { [IO.File]::Move($temporary, $request.status) }
  [IO.File]::AppendAllText($request.status + '.log', ([DateTime]::UtcNow.ToString('o') + ' ' + $state + ': ' + $message + "`r`n"))
}

function Get-AnvilReleaseFile($request, [string]$destination) {
  $curl = Join-Path $env:SystemRoot 'System32/curl.exe'
  # HTTPS remains required after redirects. Ignore .curlrc, and bound time and file size.
  & $curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' `
    --connect-timeout 20 --max-time 600 --max-filesize $request.size --output $destination -- $request.url
  if ($LASTEXITCODE -ne 0) { throw "Download failed (curl $LASTEXITCODE). Try again later." }
}

function Start-AnvilAfterUpdate($request) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $request.executable
  $start.WorkingDirectory = $request.cwd
  $start.UseShellExecute = $false
  $start.EnvironmentVariables['ANVIL_USERDIR'] = $request.userdir
  $process = [Diagnostics.Process]::Start($start)
  try {
    # A forwarded launch can exit successfully. An early startup failure must not replace the working version.
    if ($process.WaitForExit(3000) -and $process.ExitCode -ne 0) { throw "Anvil could not start (exit $($process.ExitCode))." }
  } finally { $process.Dispose() }
}

function Start-AnvilUpdateHelper([string]$scriptFile, [string]$requestPath, [string]$cwd) {
  # Explorer launches the helper outside the calling Project's or Terminal's kill-on-close job.
  $windows = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([guid]'9BA05972-F6A8-11CF-A442-00A0C90A8F39'))
  $desktopHandle = 0
  $desktop = $windows.FindWindowSW(0, 0, 8, [ref]$desktopHandle, 1)
  if (-not $desktop) { throw 'Windows Explorer is unavailable. The update did not start.' }
  $script = $scriptFile.Replace("'", "''")
  $file = $requestPath.Replace("'", "''")
  $command = "& '$script' -Mode Apply -RequestFile '$file'"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $powershell = Join-Path $PSHOME 'powershell.exe'
  $desktop.Document.Application.ShellExecute($powershell,
    ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded), $cwd, 'open', 0)
}

function Invoke-AnvilUpdate($request, [int]$CloseTimeoutSeconds = 120) {
  if ($request.version -notmatch '^\d+\.\d+\.\d+$' -or $request.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
      $request.url -notmatch '^https://github\.com/dcostap/anvil-editor/releases/download/v?\d+\.\d+\.\d+/anvil\.exe$' -or
      $request.size -le 0 -or $request.size -gt 536870912) { throw 'The update request is not valid.' }
  if (-not $request.created_at -or [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $request.created_at -gt 90) {
    throw 'The update request expired before it started. Try again.'
  }
  $app = [IO.Path]::GetFullPath($request.executable)
  if ($app -ne $request.executable) { throw 'The executable path must be absolute.' }
  $shell = [Diagnostics.Process]::GetProcessById($request.shell_pid)
  $null = $shell.Handle # Hold the process identity before asking it to close.
  if ($shell.MainModule.FileName -ne $app) { $shell.Dispose(); throw 'The running Anvil changed. Check for updates again.' }
  $lock = $null
  $stage = $null
  $backup = $null
  $closed = $false
  $installed = $false
  try {
    # A per-executable lock also protects multiple Windows, Projects and user folders.
    try { $lock = [IO.File]::Open($app + '.update-lock', 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Cannot write beside Anvil, or another update is running. Check folder permissions and try again.' }
    $originalHash = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash
    $retired = $app + '.updates'
    $null = [IO.Directory]::CreateDirectory($retired)
    # Locked old images belong to live Terminal hosts. Leave those images and every extracted runtime alone.
    foreach ($old in Get-ChildItem -LiteralPath $retired -Filter '*.exe' -File) {
      Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
    $id = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $retired ($id + '.download')
    $backup = Join-Path $retired ($id + '.exe')
    Set-AnvilUpdateStatus $request 'downloading' ('Downloading Anvil ' + $request.version)
    Get-AnvilReleaseFile $request $stage
    if ((Get-Item -LiteralPath $stage).Length -ne $request.size -or
        (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash -ne $request.sha256) {
      throw 'The download failed verification. Anvil was not changed.'
    }
    if ((Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash -ne $originalHash) {
      throw 'The executable changed during the download. Check for updates again.'
    }
    Set-AnvilUpdateStatus $request 'closing' 'Saving Workspaces. Complete any open save dialog.'
    $start = [Diagnostics.ProcessStartInfo]::new($app, '--prepare-update')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['ANVIL_USERDIR'] = $request.userdir
    $prepare = [Diagnostics.Process]::Start($start)
    try {
      if (-not $prepare.WaitForExit(30000)) { $prepare.Kill(); throw 'Anvil did not accept the update request.' }
      if ($prepare.ExitCode -ne 0) { throw 'Anvil did not accept the update request.' }
    } finally { $prepare.Dispose() }
    if (-not $shell.WaitForExit($CloseTimeoutSeconds * 1000)) {
      throw 'Anvil did not close. The executable is unchanged. Complete any save dialog, then try again.'
    }
    $closed = $true
    # Windows permits a running image to move. Existing Terminal hosts keep the old image open.
    [IO.File]::Move($app, $backup)
    try { [IO.File]::Move($stage, $app); $installed = $true }
    catch { [IO.File]::Move($backup, $app); throw }
    Start-AnvilAfterUpdate $request
    # A diagnostic write after a successful launch must not roll back a running new editor.
    try { Set-AnvilUpdateStatus $request 'done' ('Updated to Anvil ' + $request.version) } catch {}
  } catch {
    $failure = $_
    if ($closed) {
      if ($installed) {
        # Keep the rejected download out of the registered executable path.
        [IO.File]::Move($app, $stage)
        [IO.File]::Move($backup, $app)
      }
      try {
        $errors = Join-Path $request.userdir 'updates'
        $null = [IO.Directory]::CreateDirectory($errors)
        [IO.File]::WriteAllText((Join-Path $errors 'last-error.json'),
          (@{ message = $failure.Exception.Message } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
      } catch {} # A diagnostic write must not prevent recovery.
      try { Start-AnvilAfterUpdate $request } catch {
        throw ($failure.Exception.Message + ' Start Anvil manually. ' + $_.Exception.Message)
      }
    }
    throw $failure
  } finally {
    if ($stage -and [IO.File]::Exists($stage)) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue }
    if ($lock) { $lock.Dispose() }
    $shell.Dispose()
  }
}

# Tests import the functions and replace only the network boundary.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $RequestFile) { throw 'No update request.' }
$request = $null
try {
  $request = [IO.File]::ReadAllText($RequestFile) | ConvertFrom-Json
  if ($Mode -eq 'Launch') {
    Start-AnvilUpdateHelper $PSCommandPath $RequestFile $request.cwd
  } else {
    Invoke-AnvilUpdate $request
  }
} catch {
  if ($request) { Set-AnvilUpdateStatus $request 'error' $_.Exception.Message }
  Write-Error $_
  exit 1
}
