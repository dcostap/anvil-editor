param(
  [Parameter(Mandatory = $true)] [string]$Config,
  [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"
$configData = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$exe = (Resolve-Path -LiteralPath ([string]$configData.exe)).Path
$workingDirectory = [string]$configData.working_directory
if (!(Test-Path -LiteralPath $workingDirectory)) {
  throw "Working directory not found: $workingDirectory"
}

if (-not ("AnvilHiddenDesktopLauncher" -as [type])) {
  Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class AnvilHiddenDesktopResult {
  public int ProcessId;
  public int ExitCode;
  public bool TimedOut;
}

public static class AnvilHiddenDesktopLauncher {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct STARTUPINFO {
    public int cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
    public int dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct PROCESS_INFORMATION {
    public IntPtr hProcess;
    public IntPtr hThread;
    public int dwProcessId;
    public int dwThreadId;
  }

  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern IntPtr CreateDesktop(
    string lpszDesktop, IntPtr lpszDevice, IntPtr pDevmode,
    int dwFlags, uint dwDesiredAccess, IntPtr lpsa);

  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool CloseDesktop(IntPtr hDesktop);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CreateProcess(
    string lpApplicationName, StringBuilder lpCommandLine,
    IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
    bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
    string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo,
    out PROCESS_INFORMATION lpProcessInformation);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

  [DllImport("kernel32.dll")]
  private static extern bool CloseHandle(IntPtr hObject);

  private const uint DESKTOP_ALL_ACCESS = 0x000F01FF;
  private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
  private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
  private const uint WAIT_TIMEOUT = 0x00000102;

  private static string Quote(string value) {
    if (value == null) return "\"\"";
    StringBuilder quoted = new StringBuilder("\"");
    int backslashes = 0;
    foreach (char ch in value) {
      if (ch == '\\') {
        backslashes++;
      } else if (ch == '\"') {
        quoted.Append('\\', backslashes * 2 + 1).Append(ch);
        backslashes = 0;
      } else {
        quoted.Append('\\', backslashes).Append(ch);
        backslashes = 0;
      }
    }
    quoted.Append('\\', backslashes * 2).Append('\"');
    return quoted.ToString();
  }

  public static AnvilHiddenDesktopResult Run(
    string exe, string[] args, string workingDirectory,
    string desktopName, int timeoutMilliseconds) {
    IntPtr desktop = CreateDesktop(
      desktopName, IntPtr.Zero, IntPtr.Zero, 0, DESKTOP_ALL_ACCESS, IntPtr.Zero);
    if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

    PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
    try {
      STARTUPINFO si = new STARTUPINFO();
      si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      si.lpDesktop = desktopName;
      StringBuilder command = new StringBuilder(Quote(exe));
      if (args != null) {
        foreach (string arg in args) command.Append(' ').Append(Quote(arg));
      }
      if (!CreateProcess(
        exe, command, IntPtr.Zero, IntPtr.Zero, false,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP,
        IntPtr.Zero, workingDirectory, ref si, out pi)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }

      uint wait = WaitForSingleObject(pi.hProcess, checked((uint)timeoutMilliseconds));
      bool timedOut = wait == WAIT_TIMEOUT;
      if (timedOut) {
        TerminateProcess(pi.hProcess, 124);
        WaitForSingleObject(pi.hProcess, 5000);
      }
      uint exitCode;
      if (!GetExitCodeProcess(pi.hProcess, out exitCode)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      return new AnvilHiddenDesktopResult {
        ProcessId = pi.dwProcessId,
        ExitCode = unchecked((int)exitCode),
        TimedOut = timedOut
      };
    } finally {
      if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
      if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
      CloseDesktop(desktop);
    }
  }
}
"@
}

$previous = @{}
try {
  foreach ($property in $configData.environment.PSObject.Properties) {
    $name = [string]$property.Name
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, [string]$property.Value, "Process")
  }
  $arguments = @()
  foreach ($argument in $configData.arguments) { $arguments += [string]$argument }
  $desktopName = "AnvilBenchmark_" + [Guid]::NewGuid().ToString("N")
  $result = [AnvilHiddenDesktopLauncher]::Run(
    $exe, $arguments, $workingDirectory, $desktopName, $TimeoutSeconds * 1000)
  $output = [ordered]@{
    pid = $result.ProcessId
    exit_code = $result.ExitCode
    timed_out = $result.TimedOut
    desktop = $desktopName
  }
  $output | ConvertTo-Json -Compress
  if ($result.TimedOut) { exit 124 }
  exit $result.ExitCode
} finally {
  foreach ($entry in $previous.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
  }
}
