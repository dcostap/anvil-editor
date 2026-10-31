# Public seam: the update launcher must survive closure of its caller's kill job.
# Only the test's windowless processes enter the job. Do not launch the real editor.
param([ValidateSet('dev', 'release')][string]$LauncherKind = 'dev')
$ErrorActionPreference = 'Stop'
$session = (Get-Process -Id $PID).SessionId
if (-not (Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })) {
  Write-Host 'SKIP: the update launcher needs a Windows Explorer desktop.'
  exit 77
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('anvil update launch ' + [guid]::NewGuid())
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../scripts/start-dev-anvil.ps1'))
$output = Join-Path $root 'launcher.log'
$job = [IntPtr]::Zero
$caller = $null
$probe = $null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LaunchTestJob {
    [StructLayout(LayoutKind.Sequential)]
    public struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateJobObjectW(IntPtr security, IntPtr name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetInformationJobObject(IntPtr job, int kind,
        ref ExtendedLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@

function Assert-Native($ok) {
  if (-not $ok) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
}

function Wait-For($condition, $message) {
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (& $condition)) {
    if ($caller -and $caller.HasExited) { throw "The launcher caller exited before it was ready: $message" }
    if ([DateTime]::UtcNow -ge $deadline) { throw $message }
    Start-Sleep -Milliseconds 25
  }
}

try {
  [IO.Directory]::CreateDirectory($root) | Out-Null
  $app = Join-Path $root 'anvil.exe'
  # A windowless stand-in reports its PID and waits for test cleanup.
  Add-Type -OutputAssembly $app -OutputType WindowsApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
public static class UpdateLaunchProbe {
    public static void Main() {
        string app = Assembly.GetExecutingAssembly().Location;
        File.WriteAllText(app + ".pid", Process.GetCurrentProcess().Id.ToString());
        while (!File.Exists(app + ".stop")) Thread.Sleep(25);
    }
}
'@
  $job = [LaunchTestJob]::CreateJobObjectW([IntPtr]::Zero, [IntPtr]::Zero)
  Assert-Native ($job -ne [IntPtr]::Zero)
  $limits = New-Object LaunchTestJob+ExtendedLimits
  $basic = New-Object LaunchTestJob+BasicLimits
  $basic.Flags = 0x2000 # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway permitted.
  $limits.Basic = $basic
  Assert-Native ([LaunchTestJob]::SetInformationJobObject($job, 9, [ref]$limits,
    [Runtime.InteropServices.Marshal]::SizeOf($limits)))

  $go = Join-Path $root 'go'
  $returned = Join-Path $root 'returned'
  $launchCall = "& '$launcher' -AppRoot '$root'"
  if ($LauncherKind -eq 'release') {
    $releaseLauncher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../data/tools/updater.ps1'))
    $fixture = Join-Path $root "helper's script.ps1"
    [IO.File]::WriteAllText($fixture, @'
param($Mode, $RequestFile)
if ($Mode -ne 'Apply' -or $RequestFile -notlike "*request's file.json") { exit 1 }
$info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSScriptRoot 'anvil.exe'))
$info.UseShellExecute = $false
$process = [Diagnostics.Process]::Start($info)
$process.WaitForExit()
'@)
    $quotedFixture = $fixture.Replace("'", "''")
    $request = (Join-Path $root "request's file.json").Replace("'", "''")
    $launchCall = ". '$releaseLauncher'; Start-AnvilUpdateHelper '$quotedFixture' '$request' '$root'"
  }
  # Hold the caller until it belongs to the job, before it can launch a child.
  $command = "while (-not (Test-Path -LiteralPath '$go')) { Start-Sleep -Milliseconds 25 }; & { $launchCall } *> '$output'; if (-not `$?) { exit 1 }; [IO.File]::WriteAllText('$returned', ''); Start-Sleep -Seconds 300"
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = Join-Path $PSHOME 'powershell.exe'
  $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' +
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $caller = [Diagnostics.Process]::Start($start)
  Assert-Native ([LaunchTestJob]::AssignProcessToJobObject($job, $caller.Handle))
  [IO.File]::WriteAllText($go, '')
  Wait-For { Test-Path -LiteralPath ($app + '.pid') } 'The launched app did not report ready.'
  $probe = [Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($app + '.pid'))
  # Cache a handle before the job closes, so a reused PID cannot pass the test.
  $null = $probe.Handle
  Wait-For { Test-Path -LiteralPath $returned } 'The launcher did not return.'

  Assert-Native ([LaunchTestJob]::CloseHandle($job))
  $job = [IntPtr]::Zero
  if (-not $caller.WaitForExit(30000)) { throw 'The test Terminal did not close.' }
  if ($probe.WaitForExit(1000)) {
    throw 'Closing the Terminal process group killed the launched app.'
  }
  [IO.File]::WriteAllText($app + '.stop', '')
  if (-not $probe.WaitForExit(30000)) { throw 'The launched app did not stop after the test.' }
  Write-Host 'PASS: closing the caller process group leaves the launched app running.'
} catch {
  if (Test-Path -LiteralPath $output) { Write-Host ([IO.File]::ReadAllText($output)) }
  throw
} finally {
  if ($job -ne [IntPtr]::Zero) { $null = [LaunchTestJob]::CloseHandle($job) }
  foreach ($process in @($probe, $caller)) {
    if ($process) {
      if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
      $process.Dispose()
    }
  }
  if (Test-Path -LiteralPath $root) {
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
      try { Remove-Item -LiteralPath $root -Recurse -Force; break }
      catch { if ($attempt -eq 39) { throw }; Start-Sleep -Milliseconds 100 }
    }
  }
}
