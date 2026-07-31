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
  public string TerminationReason;
  public string LastPhase;
  public long ElapsedMilliseconds;
  public long FirstHeartbeatMilliseconds;
  public bool ProcessTreeTerminated;
  public long PeakWorkingSetBytes;
  public long PeakPrivateBytes;
  public bool DumpWritten;
  public string DumpPath;
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

  [StructLayout(LayoutKind.Sequential)]
  private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct IO_COUNTERS {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
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

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool SetInformationJobObject(
    IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint ResumeThread(IntPtr hThread);

  [DllImport("Dbghelp.dll", SetLastError = true)]
  private static extern bool MiniDumpWriteDump(
    IntPtr hProcess, uint processId, IntPtr hFile, uint dumpType,
    IntPtr exceptionParam, IntPtr userStreamParam, IntPtr callbackParam);

  [DllImport("kernel32.dll")]
  private static extern bool CloseHandle(IntPtr hObject);

  private const uint DESKTOP_ALL_ACCESS = 0x000F01FF;
  private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
  private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
  private const uint CREATE_SUSPENDED = 0x00000004;
  private const uint WAIT_TIMEOUT = 0x00000102;
  private const uint WAIT_OBJECT_0 = 0;
  private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
  private const int JobObjectExtendedLimitInformation = 9;
  private const uint MiniDumpWithUnloadedModules = 0x00000020;
  private const uint MiniDumpWithThreadInfo = 0x00001000;

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

  private static IntPtr CreateKillOnCloseJob() {
    IntPtr job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    IntPtr buffer = Marshal.AllocHGlobal(size);
    try {
      Marshal.StructureToPtr(limits, buffer, false);
      if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size)) {
        int error = Marshal.GetLastWin32Error();
        CloseHandle(job);
        throw new Win32Exception(error);
      }
    } finally {
      Marshal.FreeHGlobal(buffer);
    }
    return job;
  }

  private static string ReadPhase(string heartbeatPath) {
    if (String.IsNullOrEmpty(heartbeatPath) || !System.IO.File.Exists(heartbeatPath)) return "";
    try {
      foreach (string line in System.IO.File.ReadAllLines(heartbeatPath)) {
        if (line.StartsWith("phase=")) return line.Substring(6).Trim();
      }
    } catch (System.IO.IOException) {
      // The benchmark replaces this file atomically; retry on the next poll.
    } catch (UnauthorizedAccessException) {}
    return "";
  }

  private static void SampleResources(
    int processId, long elapsedMs, string phase, string resourceSamplesPath,
    ref long peakWorkingSet, ref long peakPrivate) {
    try {
      using (System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(processId)) {
        process.Refresh();
        long workingSet = process.WorkingSet64;
        long privateBytes = process.PrivateMemorySize64;
        peakWorkingSet = Math.Max(peakWorkingSet, workingSet);
        peakPrivate = Math.Max(peakPrivate, privateBytes);
        if (!String.IsNullOrEmpty(resourceSamplesPath)) {
          string cleanPhase = (phase ?? "").Replace(',', '_').Replace('\r', ' ').Replace('\n', ' ');
          System.IO.File.AppendAllText(
            resourceSamplesPath,
            String.Format("{0},{1},{2},{3}\n", elapsedMs, workingSet, privateBytes, cleanPhase));
        }
      }
    } catch (ArgumentException) {
      // The process exited between the wait and sample.
    } catch (InvalidOperationException) {
    } catch (System.IO.IOException) {
    }
  }

  private static bool WriteTimeoutDump(IntPtr process, int processId, string path) {
    if (String.IsNullOrEmpty(path)) return false;
    try {
      string directory = System.IO.Path.GetDirectoryName(path);
      if (!String.IsNullOrEmpty(directory)) System.IO.Directory.CreateDirectory(directory);
      using (System.IO.FileStream stream = new System.IO.FileStream(
        path, System.IO.FileMode.Create, System.IO.FileAccess.Write, System.IO.FileShare.None)) {
        return MiniDumpWriteDump(
          process, (uint)processId, stream.SafeFileHandle.DangerousGetHandle(),
          MiniDumpWithUnloadedModules | MiniDumpWithThreadInfo,
          IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
      }
    } catch (System.IO.IOException) {
      return false;
    } catch (UnauthorizedAccessException) {
      return false;
    }
  }

  public static AnvilHiddenDesktopResult Run(
    string exe, string[] args, string workingDirectory,
    string desktopName, int timeoutMilliseconds, string heartbeatPath,
    int startupTimeoutMilliseconds, int heartbeatTimeoutMilliseconds,
    string resourceSamplesPath, string timeoutDumpPath) {
    IntPtr desktop = CreateDesktop(
      desktopName, IntPtr.Zero, IntPtr.Zero, 0, DESKTOP_ALL_ACCESS, IntPtr.Zero);
    if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

    PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
    IntPtr job = IntPtr.Zero;
    try {
      job = CreateKillOnCloseJob();
      STARTUPINFO si = new STARTUPINFO();
      si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      si.lpDesktop = desktopName;
      StringBuilder command = new StringBuilder(Quote(exe));
      if (args != null) {
        foreach (string arg in args) command.Append(' ').Append(Quote(arg));
      }
      if (!CreateProcess(
        exe, command, IntPtr.Zero, IntPtr.Zero, false,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED,
        IntPtr.Zero, workingDirectory, ref si, out pi)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }

      if (!AssignProcessToJobObject(job, pi.hProcess)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      if (ResumeThread(pi.hThread) == UInt32.MaxValue) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }

      if (!String.IsNullOrEmpty(resourceSamplesPath)) {
        System.IO.File.WriteAllText(resourceSamplesPath, "elapsed_ms,working_set_bytes,private_bytes,phase\n");
      }
      System.Diagnostics.Stopwatch timer = System.Diagnostics.Stopwatch.StartNew();
      long firstHeartbeatMs = -1, lastHeartbeatMs = -1;
      DateTime lastHeartbeatWrite = DateTime.MinValue;
      string lastPhase = "not_started";
      string terminationReason = "";
      long peakWorkingSet = 0, peakPrivate = 0;
      long nextResourceSampleMs = 0;
      while (true) {
        uint wait = WaitForSingleObject(pi.hProcess, 50);
        if (wait == WAIT_OBJECT_0) break;
        long elapsed = timer.ElapsedMilliseconds;
        if (!String.IsNullOrEmpty(heartbeatPath) && System.IO.File.Exists(heartbeatPath)) {
          try {
            DateTime write = System.IO.File.GetLastWriteTimeUtc(heartbeatPath);
            if (write != lastHeartbeatWrite) {
              lastHeartbeatWrite = write;
              lastHeartbeatMs = elapsed;
              if (firstHeartbeatMs < 0) firstHeartbeatMs = elapsed;
              string phase = ReadPhase(heartbeatPath);
              if (!String.IsNullOrEmpty(phase)) lastPhase = phase;
            }
          } catch (System.IO.IOException) {}
        }
        if (elapsed >= nextResourceSampleMs) {
          SampleResources(pi.dwProcessId, elapsed, lastPhase, resourceSamplesPath,
            ref peakWorkingSet, ref peakPrivate);
          nextResourceSampleMs = elapsed + 250;
        }
        if (elapsed >= timeoutMilliseconds) {
          terminationReason = "wall_timeout";
          break;
        }
        if (lastHeartbeatMs < 0 && startupTimeoutMilliseconds > 0
            && elapsed >= startupTimeoutMilliseconds) {
          terminationReason = "startup_stall";
          break;
        }
        if (lastHeartbeatMs >= 0 && heartbeatTimeoutMilliseconds > 0
            && elapsed - lastHeartbeatMs >= heartbeatTimeoutMilliseconds) {
          terminationReason = "heartbeat_stall";
          break;
        }
      }
      bool timedOut = !String.IsNullOrEmpty(terminationReason);
      bool processTreeTerminated = false;
      bool dumpWritten = false;
      if (timedOut) {
        dumpWritten = WriteTimeoutDump(pi.hProcess, pi.dwProcessId, timeoutDumpPath);
        processTreeTerminated = TerminateJobObject(job, 124);
        if (!processTreeTerminated) TerminateProcess(pi.hProcess, 124);
        WaitForSingleObject(pi.hProcess, 5000);
      }
      SampleResources(pi.dwProcessId, timer.ElapsedMilliseconds, lastPhase, resourceSamplesPath,
        ref peakWorkingSet, ref peakPrivate);
      uint exitCode;
      if (!GetExitCodeProcess(pi.hProcess, out exitCode)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      return new AnvilHiddenDesktopResult {
        ProcessId = pi.dwProcessId,
        ExitCode = unchecked((int)exitCode),
        TimedOut = timedOut,
        TerminationReason = terminationReason,
        LastPhase = lastPhase,
        ElapsedMilliseconds = timer.ElapsedMilliseconds,
        FirstHeartbeatMilliseconds = firstHeartbeatMs,
        ProcessTreeTerminated = processTreeTerminated,
        PeakWorkingSetBytes = peakWorkingSet,
        PeakPrivateBytes = peakPrivate,
        DumpWritten = dumpWritten,
        DumpPath = dumpWritten ? timeoutDumpPath : ""
      };
    } catch {
      // CreateProcess uses CREATE_SUSPENDED so setup failures cannot race with
      // child creation. If assignment itself failed, terminate the direct
      // process because it is not yet protected by the Job Object.
      if (job != IntPtr.Zero) TerminateJobObject(job, 125);
      if (pi.hProcess != IntPtr.Zero) TerminateProcess(pi.hProcess, 125);
      throw;
    } finally {
      if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
      if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
      if (job != IntPtr.Zero) CloseHandle(job);
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
  $heartbeatPath = if ($configData.PSObject.Properties.Name -contains "heartbeat_path") {
    [string]$configData.heartbeat_path
  } else { "" }
  $resourceSamplesPath = if ($configData.PSObject.Properties.Name -contains "resource_samples_path") {
    [string]$configData.resource_samples_path
  } else { "" }
  $timeoutDumpPath = if ($configData.PSObject.Properties.Name -contains "timeout_dump_path") {
    [string]$configData.timeout_dump_path
  } else { "" }
  $startupTimeoutSeconds = if ($configData.PSObject.Properties.Name -contains "startup_timeout_seconds") {
    [int]$configData.startup_timeout_seconds
  } else { 0 }
  $heartbeatTimeoutSeconds = if ($configData.PSObject.Properties.Name -contains "heartbeat_timeout_seconds") {
    [int]$configData.heartbeat_timeout_seconds
  } else { 0 }
  $desktopName = "AnvilBenchmark_" + [Guid]::NewGuid().ToString("N")
  $result = [AnvilHiddenDesktopLauncher]::Run(
    $exe, $arguments, $workingDirectory, $desktopName, $TimeoutSeconds * 1000,
    $heartbeatPath, $startupTimeoutSeconds * 1000, $heartbeatTimeoutSeconds * 1000,
    $resourceSamplesPath, $timeoutDumpPath)
  $output = [ordered]@{
    pid = $result.ProcessId
    exit_code = $result.ExitCode
    timed_out = $result.TimedOut
    termination_reason = $result.TerminationReason
    last_phase = $result.LastPhase
    elapsed_ms = $result.ElapsedMilliseconds
    first_heartbeat_ms = $result.FirstHeartbeatMilliseconds
    process_tree_terminated = $result.ProcessTreeTerminated
    peak_working_set_bytes = $result.PeakWorkingSetBytes
    peak_private_bytes = $result.PeakPrivateBytes
    dump_written = $result.DumpWritten
    dump_path = $result.DumpPath
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
