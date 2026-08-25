param(
  [string]$AnvilExe = "",
  [ValidateSet("d3d11", "software")]
  [string]$Renderer = "d3d11",
  [int]$SwitchCount = 20,
  [int]$StartupTimeoutSeconds = 35
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $AnvilExe) {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
  $AnvilExe = Join-Path $repoRoot "build-windows-x86_64\src\anvil.exe"
}
$AnvilExe = (Resolve-Path $AnvilExe).Path

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class HandoffNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT {
    public uint Type;
    public INPUTUNION Data;
  }

  [StructLayout(LayoutKind.Explicit)]
  public struct INPUTUNION {
    [FieldOffset(0)] public KEYBDINPUT Keyboard;
    [FieldOffset(0)] public MOUSEINPUT Mouse;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT {
    public ushort VirtualKey;
    public ushort ScanCode;
    public uint Flags;
    public uint Time;
    public IntPtr ExtraInfo;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT {
    public int X;
    public int Y;
    public uint MouseData;
    public uint Flags;
    public uint Time;
    public IntPtr ExtraInfo;
  }

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsWindow(IntPtr hwnd);

  [DllImport("user32.dll")]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsWindowVisible(IntPtr hwnd);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

  [DllImport("user32.dll")]
  public static extern IntPtr GetParent(IntPtr hwnd);

  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
  public static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

  [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
  public static extern IntPtr GetWindowLong32(IntPtr hwnd, int index);

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr GetPropW(IntPtr hwnd, string name);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool IsZoomed(IntPtr hwnd);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool ShowWindow(IntPtr hwnd, int command);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool SetForegroundWindow(IntPtr hwnd);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool SetWindowPos(
    IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

  [DllImport("user32.dll")]
  public static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

  public static long GetWindowLong(IntPtr hwnd, int index) {
    return IntPtr.Size == 8
      ? GetWindowLongPtr64(hwnd, index).ToInt64()
      : GetWindowLong32(hwnd, index).ToInt64();
  }

  public static bool SendUnicodeCharacter(char character) {
    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;
    INPUT[] inputs = new INPUT[2];
    inputs[0].Type = INPUT_KEYBOARD;
    inputs[0].Data.Keyboard.ScanCode = character;
    inputs[0].Data.Keyboard.Flags = KEYEVENTF_UNICODE;
    inputs[1].Type = INPUT_KEYBOARD;
    inputs[1].Data.Keyboard.ScanCode = character;
    inputs[1].Data.Keyboard.Flags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
  }
}
"@

# Use the same per-monitor coordinate space as Anvil. Without this, USER32 can
# virtualize one HWND through a different monitor and report a false position.
[void][HandoffNative]::SetThreadDpiAwarenessContext([IntPtr](-4))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Wait-Until {
  param(
    [scriptblock]$Condition,
    [int]$TimeoutSeconds,
    [string]$FailureMessage
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    if (& $Condition) { return }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  throw $FailureMessage
}

function Read-ProbeState {
  param([string]$Path)
  $values = @{}
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $parts = $line -split "=", 2
    if ($parts.Count -eq 2) { $values[$parts[0]] = $parts[1] }
  }
  return $values
}

function Get-WindowRectValue {
  param([IntPtr]$Hwnd)
  $rect = New-Object HandoffNative+RECT
  Assert-True ([HandoffNative]::GetWindowRect($Hwnd, [ref]$rect)) "GetWindowRect failed for $Hwnd"
  return @{
    X = $rect.Left
    Y = $rect.Top
    Width = $rect.Right - $rect.Left
    Height = $rect.Bottom - $rect.Top
  }
}

function Assert-SameBounds {
  param($Expected, $Actual, [string]$Context)
  foreach ($name in @("X", "Y", "Width", "Height")) {
    $difference = [Math]::Abs([int]$Expected[$name] - [int]$Actual[$name])
    Assert-True ($difference -le 2) "$Context changed $name from $($Expected[$name]) to $($Actual[$name])"
  }
}

function Send-ProbeCommand {
  param([int]$ManagerPid, [string]$Command)
  $pipeName = "AnvilWindowHandoffProbe-$ManagerPid"
  $client = New-Object System.IO.Pipes.NamedPipeClientStream(
    ".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::None)
  try {
    $client.Connect(5000)
    $writer = New-Object System.IO.StreamWriter($client, [Text.Encoding]::ASCII, 1024, $true)
    $reader = New-Object System.IO.StreamReader($client, [Text.Encoding]::ASCII, $false, 1024, $true)
    $writer.NewLine = "`n"
    $writer.WriteLine($Command)
    $writer.Flush()
    $reply = $reader.ReadLine()
    if (-not $reply) { throw "The handoff manager returned no reply for '$Command'." }
    return $reply
  } finally {
    $client.Dispose()
  }
}

function Send-TextCharacter {
  param([IntPtr]$Hwnd, [char]$Character)
  Assert-True ([HandoffNative]::GetForegroundWindow() -eq $Hwnd) "Text target is not foreground."
  Assert-True ([HandoffNative]::SendUnicodeCharacter($Character)) "SendInput failed for $Hwnd"
}

$probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("anvil-window-handoff-" + [Guid]::NewGuid().ToString("N"))
$projectA = Join-Path $probeRoot "project-a"
$projectB = Join-Path $probeRoot "project-b"
$userDir = Join-Path $probeRoot "user"
$stateFile = Join-Path $probeRoot "state.txt"
$fileA = Join-Path $projectA "handoff.txt"
$fileB = Join-Path $projectB "handoff.txt"

[System.IO.Directory]::CreateDirectory($projectA) | Out-Null
[System.IO.Directory]::CreateDirectory($projectB) | Out-Null
[System.IO.Directory]::CreateDirectory($userDir) | Out-Null
[System.IO.File]::WriteAllText($fileA, "")
[System.IO.File]::WriteAllText($fileB, "")

$process = $null
try {
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $AnvilExe
  $startInfo.Arguments = "--window-handoff-probe-manager `"$projectA`" `"$projectB`""
  $startInfo.WorkingDirectory = $probeRoot
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardError = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.EnvironmentVariables["ANVIL_USERDIR"] = $userDir
  $startInfo.EnvironmentVariables["ANVIL_RENDERER"] = $Renderer
  $startInfo.EnvironmentVariables["ANVIL_WINDOW_HANDOFF_PROBE_STATE_FILE"] = $stateFile

  $process = [System.Diagnostics.Process]::Start($startInfo)
  Assert-True ($null -ne $process) "Anvil did not start."

  Wait-Until {
    if ($process.HasExited) {
      $errorOutput = $process.StandardError.ReadToEnd()
      throw "The handoff manager exited before startup. Exit=$($process.ExitCode) Error=$errorOutput"
    }
    Test-Path $stateFile -PathType Leaf
  } $StartupTimeoutSeconds "The handoff manager did not publish probe state."

  $state = Read-ProbeState $stateFile
  foreach ($required in @("manager_pid", "child_a_pid", "child_b_pid", "hwnd_a", "hwnd_b", "active")) {
    Assert-True $state.ContainsKey($required) "Probe state has no '$required' value."
  }

  $managerPid = [int]$state["manager_pid"]
  Assert-True ($managerPid -eq $process.Id) "Probe state identifies the wrong manager process."

  $childAPid = [uint32]$state["child_a_pid"]
  $childBPid = [uint32]$state["child_b_pid"]
  Assert-True ($childAPid -ne $childBPid) "Projects did not start in separate processes."

  $hwndA = [IntPtr]([Int64]$state["hwnd_a"])
  $hwndB = [IntPtr]([Int64]$state["hwnd_b"])
  Assert-True ([HandoffNative]::IsWindow($hwndA)) "Project A has no valid top-level window."
  Assert-True ([HandoffNative]::IsWindow($hwndB)) "Project B has no valid top-level window."
  Assert-True ([HandoffNative]::GetParent($hwndA) -eq [IntPtr]::Zero) "Project A is not a top-level window."
  Assert-True ([HandoffNative]::GetParent($hwndB) -eq [IntPtr]::Zero) "Project B is not a top-level window."

  $WS_CHILD = 0x40000000L
  Assert-True (([HandoffNative]::GetWindowLong($hwndA, -16) -band $WS_CHILD) -eq 0) "Project A uses WS_CHILD."
  Assert-True (([HandoffNative]::GetWindowLong($hwndB, -16) -band $WS_CHILD) -eq 0) "Project B uses WS_CHILD."

  $ownerPidA = [uint32]0
  $ownerPidB = [uint32]0
  [void][HandoffNative]::GetWindowThreadProcessId($hwndA, [ref]$ownerPidA)
  [void][HandoffNative]::GetWindowThreadProcessId($hwndB, [ref]$ownerPidB)
  Assert-True ($ownerPidA -eq $childAPid) "Project A HWND belongs to the wrong process."
  Assert-True ($ownerPidB -eq $childBPid) "Project B HWND belongs to the wrong process."

  $activeName = $state["active"]
  Assert-True ($activeName -eq "a") "Project A did not start selected."
  Assert-True ([HandoffNative]::IsWindowVisible($hwndA)) "Selected Project A is hidden."
  Assert-True (-not [HandoffNative]::IsWindowVisible($hwndB)) "Unselected Project B is visible."

  $frameProperty = "AnvilWindowHandoffFrameGeneration"
  $hiddenGeneration = [HandoffNative]::GetPropW($hwndB, $frameProperty).ToInt64()
  Start-Sleep -Milliseconds 300
  Assert-True (
    [HandoffNative]::GetPropW($hwndB, $frameProperty).ToInt64() -eq $hiddenGeneration
  ) "Hidden Project B continued rendering."

  $SWP_NOZORDER = 0x0004
  $SWP_NOACTIVATE = 0x0010
  $SW_RESTORE = 9
  [void][HandoffNative]::ShowWindow($hwndA, $SW_RESTORE)
  Wait-Until { -not [HandoffNative]::IsZoomed($hwndA) } 5 "Project A did not enter normal mode."
  Assert-True ([HandoffNative]::SetWindowPos(
    $hwndA, [IntPtr]::Zero, 180, 140, 960, 680, $SWP_NOZORDER -bor $SWP_NOACTIVATE)) "Initial resize failed."
  Start-Sleep -Milliseconds 300

  $expectedA = New-Object System.Text.StringBuilder
  $expectedB = New-Object System.Text.StringBuilder
  $activeHwnd = $hwndA
  $inactiveHwnd = $hwndB
  $activeName = "a"

  for ($index = 0; $index -lt $SwitchCount; $index++) {
    $oldBounds = Get-WindowRectValue $activeHwnd
    $reply = Send-ProbeCommand $managerPid "switch"
    if (-not $reply.StartsWith("OK ")) {
      [void]$process.WaitForExit(5000)
      $managerError = $process.StandardError.ReadToEnd()
      throw "Handoff $($index + 1) failed: $reply $managerError"
    }

    $oldHwnd = $activeHwnd
    $activeHwnd = $inactiveHwnd
    $inactiveHwnd = $oldHwnd
    $activeName = if ($activeName -eq "a") { "b" } else { "a" }

    Wait-Until {
      [HandoffNative]::IsWindowVisible($activeHwnd) -and
        -not [HandoffNative]::IsWindowVisible($inactiveHwnd)
    } 5 "The handoff did not leave exactly one Project window visible."

    $newBounds = Get-WindowRectValue $activeHwnd
    Assert-SameBounds $oldBounds $newBounds "Switch $($index + 1) ($reply)"

    Wait-Until {
      [HandoffNative]::GetForegroundWindow() -eq $activeHwnd
    } 5 "Switch $($index + 1) did not focus the selected Project window."

    $character = if ($activeName -eq "a") { [char]"a" } else { [char]"b" }
    Send-TextCharacter $activeHwnd $character
    if ($activeName -eq "a") { [void]$expectedA.Append($character) }
    else { [void]$expectedB.Append($character) }
    Start-Sleep -Milliseconds 120
  }

  try {
    Wait-Until {
      ([System.IO.File]::ReadAllText($fileA).TrimEnd([char[]]@("`r", "`n")) -eq $expectedA.ToString()) -and
        ([System.IO.File]::ReadAllText($fileB).TrimEnd([char[]]@("`r", "`n")) -eq $expectedB.ToString())
    } 12 "Typed text did not save in both Project processes."
  } catch {
    $actualA = [System.IO.File]::ReadAllText($fileA)
    $actualB = [System.IO.File]::ReadAllText($fileB)
    $savedAtDeadline =
      $actualA.TrimEnd([char[]]@("`r", "`n")) -eq $expectedA.ToString() -and
      $actualB.TrimEnd([char[]]@("`r", "`n")) -eq $expectedB.ToString()
    if (-not $savedAtDeadline) {
      throw "Typed text did not save. A='$actualA' expected='$expectedA'; B='$actualB' expected='$expectedB'."
    }
  }

  $visibleCount = 0
  foreach ($hwnd in @($hwndA, $hwndB)) {
    if ([HandoffNative]::IsWindowVisible($hwnd)) { $visibleCount++ }
  }
  Assert-True ($visibleCount -eq 1) "The logical Anvil Window has $visibleCount visible Project windows."

  $hiddenGeneration = [HandoffNative]::GetPropW($inactiveHwnd, $frameProperty).ToInt64()
  Start-Sleep -Milliseconds 300
  Assert-True (
    [HandoffNative]::GetPropW($inactiveHwnd, $frameProperty).ToInt64() -eq $hiddenGeneration
  ) "The inactive Project continued rendering after repeated switches."

  $SW_MAXIMIZE = 3
  [void][HandoffNative]::ShowWindow($activeHwnd, $SW_MAXIMIZE)
  Wait-Until { [HandoffNative]::IsZoomed($activeHwnd) } 5 "The selected Project did not maximize."
  $maximizedBounds = Get-WindowRectValue $activeHwnd
  $reply = Send-ProbeCommand $managerPid "switch"
  Assert-True $reply.StartsWith("OK ") "Maximized handoff failed: $reply"
  $oldHwnd = $activeHwnd
  $activeHwnd = $inactiveHwnd
  $inactiveHwnd = $oldHwnd
  Wait-Until {
    [HandoffNative]::IsWindowVisible($activeHwnd) -and
      -not [HandoffNative]::IsWindowVisible($inactiveHwnd) -and
      [HandoffNative]::IsZoomed($activeHwnd)
  } 5 "The target Project did not preserve maximized mode."
  Assert-SameBounds $maximizedBounds (Get-WindowRectValue $activeHwnd) "Maximized switch"
  [void][HandoffNative]::ShowWindow($activeHwnd, $SW_RESTORE)
  Wait-Until { -not [HandoffNative]::IsZoomed($activeHwnd) } 5 "The selected Project did not restore."

  $stopReply = Send-ProbeCommand $managerPid "stop"
  Assert-True $stopReply.StartsWith("OK ") "The manager rejected stop: $stopReply"
  Assert-True ($process.WaitForExit(10000)) "The handoff manager did not exit after stop."
  Assert-True ($process.ExitCode -eq 0) "The handoff manager exited with code $($process.ExitCode)."

  Write-Host "PASS: $Renderer handoff used two top-level Project processes across $SwitchCount switches."
} finally {
  if ($process -and -not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
