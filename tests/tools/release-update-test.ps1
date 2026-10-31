# Only private, windowless fixture programs run here. No installed editor or network is used.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../data/tools/updater.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('anvil release update ' + [guid]::NewGuid())
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Wait-File($path) {
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not [IO.File]::Exists($path)) {
    if ([DateTime]::UtcNow -gt $deadline) { throw "No fixture report: $path" }
    Start-Sleep -Milliseconds 25
  }
}
function Start-Fixture($path, $arguments = '') {
  $info = [Diagnostics.ProcessStartInfo]::new($path, $arguments)
  $info.UseShellExecute = $false
  $process = [Diagnostics.Process]::Start($info)
  $null = $process.Handle
  $processes.Add($process)
  return $process
}
# The download is the external boundary. The installer still checks its bytes, size and SHA-256.
function Get-AnvilReleaseFile($request, $destination) {
  [IO.File]::Copy($script:download, $destination)
}
try {
  $null = [IO.Directory]::CreateDirectory($root)
  foreach ($version in 'old', 'new') {
    $source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
public static class UpdateFixtureVERSION {
  public static void Main(string[] args) {
    string path = Assembly.GetExecutingAssembly().Location;
    if (args.Length > 0 && args[0] == "--prepare-update") {
      File.WriteAllText(path + ".close", ""); return;
    }
    bool host = args.Length > 0 && args[0] == "--terminal-session";
    bool refuse = args.Length > 0 && args[0] == "--refuse";
    if (!host) File.Delete(path + ".close");
    File.WriteAllText(path + (host ? ".host" : ".started"), Process.GetCurrentProcess().Id.ToString());
    while (host || refuse || !File.Exists(path + ".close")) Thread.Sleep(25);
  }
}
'@
    Add-Type -TypeDefinition ($source.Replace('VERSION', $version)) -OutputType WindowsApplication -OutputAssembly (Join-Path $root ($version + '.exe'))
  }
  Add-Type -TypeDefinition 'public static class BrokenUpdateFixture { public static void Main() { System.Environment.Exit(7); } }' `
    -OutputType WindowsApplication -OutputAssembly (Join-Path $root 'broken.exe')
  foreach ($case in 'digest', 'cancel', 'locked', 'startup', 'success') {
    $script:download = Join-Path $root $(if ($case -eq 'startup') { 'broken.exe' } else { 'new.exe' })
    $digest = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant()
    $size = (Get-Item -LiteralPath $download).Length
    $folder = Join-Path $root $case
    $null = [IO.Directory]::CreateDirectory($folder)
    $app = Join-Path $folder 'anvil.exe'
    [IO.File]::Copy((Join-Path $root 'old.exe'), $app)
    $oldHash = (Get-FileHash -LiteralPath $app).Hash
    $shell = Start-Fixture $app $(if ($case -eq 'cancel') { '--refuse' } else { '' })
    Wait-File ($app + '.started')
    $request = [pscustomobject]@{
      executable = $app; userdir = $folder; cwd = $folder; shell_pid = $shell.Id
      created_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      version = '2.0.0'; url = 'https://github.com/dcostap/anvil-editor/releases/download/v2.0.0/anvil.exe'
      sha256 = $digest; size = $size; status = (Join-Path $folder 'status.json')
    }
    $hostProcess = $null
    $lock = $null
    try {
      if ($case -eq 'digest') { $request.sha256 = '0' * 64 }
      if ($case -eq 'success') {
        $hostProcess = Start-Fixture $app '--terminal-session'
        Wait-File ($app + '.host')
      }
      if ($case -eq 'locked') {
        $lock = [IO.File]::Open($app, 'Open', 'Read', 'Read')
      }
      $failed = $false
      try { Invoke-AnvilUpdate $request -CloseTimeoutSeconds 1 } catch {
        $failed = $true
        Write-Host ($case + ': ' + $_.Exception.Message)
      }
      if ($case -eq 'success') {
        Assert (-not $failed) 'The update failed.'
        Assert ((Get-FileHash -LiteralPath $app).Hash.ToLowerInvariant() -eq $digest) 'The new executable is not installed.'
        Assert (-not $hostProcess.HasExited) 'The update ended the Terminal host.'
        $restarted = [int][IO.File]::ReadAllText($app + '.started')
        Assert ($restarted -ne $shell.Id) 'The new executable did not start.'
        $processes.Add([Diagnostics.Process]::GetProcessById($restarted))
      } else {
        Assert $failed "The $case case did not fail."
        $status = [IO.File]::ReadAllText($request.status) | ConvertFrom-Json
        Assert ($status.state -eq $(if ($case -eq 'digest') { 'downloading' } else { 'closing' })) 'The failure occurred before the tested operation.'
        Assert ((Get-FileHash -LiteralPath $app).Hash -eq $oldHash) "The $case failure changed the executable."
        if ($case -in 'digest', 'cancel') { Assert (-not $shell.HasExited) 'The failed update killed the shell.' }
        if ($case -in 'locked', 'startup') {
          Assert ([int][IO.File]::ReadAllText($app + '.started') -ne $shell.Id) 'The original executable did not restart.'
        }
      }
      Write-Host "PASS: $case"
    } finally {
      if ($lock) { $lock.Dispose() }
      # Also collect an original executable restarted after a failed replacement.
      if ([IO.File]::Exists($app + '.started')) {
        $started = Get-Process -Id ([int][IO.File]::ReadAllText($app + '.started')) -ErrorAction SilentlyContinue
        if ($started) { $processes.Add($started) }
      }
    }
  }
} finally {
  foreach ($process in $processes) {
    try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() } catch {}
  }
  if (Test-Path -LiteralPath $root) {
    for ($i = 0; $i -lt 50; $i++) {
      try { Remove-Item -LiteralPath $root -Recurse -Force; break }
      catch { if ($i -eq 49) { throw }; Start-Sleep -Milliseconds 100 }
    }
  }
}
