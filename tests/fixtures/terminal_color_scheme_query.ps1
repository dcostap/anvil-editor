param([switch]$Watch)

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleMode {
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr GetStdHandle(int kind);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
'@

$inputHandle = [ConsoleMode]::GetStdHandle(-10)
$mode = 0
if (-not [ConsoleMode]::GetConsoleMode($inputHandle, [ref]$mode)) { exit 2 }
$rawMode = ($mode -band (-bnot 0x0007)) -bor 0x0200
if (-not [ConsoleMode]::SetConsoleMode($inputHandle, $rawMode)) { exit 3 }

$escape = [char]27
[Console]::Write($escape + '[?996n')
$inputStream = [Console]::OpenStandardInput()
$bytes = New-Object System.Collections.Generic.List[byte]
do {
  $byte = $inputStream.ReadByte()
  if ($byte -ge 0) { $bytes.Add($byte) }
} until ($byte -eq 110)
$response = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
if ($response -eq ($escape + '[?997;2n')) {
  [Console]::Write('ANVIL_LIGHT_SCHEME')
}

if ($Watch) {
  [Console]::Write($escape + '[?2031h' + 'ANVIL_WATCH_READY')
  foreach ($scheme in @(1, 2)) {
    $bytes.Clear()
    do {
      $byte = $inputStream.ReadByte()
      if ($byte -lt 0) { exit 4 }
      $bytes.Add($byte)
    } until ($byte -eq 110)
    $response = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
    if ($response -ne ($escape + '[?997;' + $scheme + 'n')) { exit 5 }
    [Console]::Write('ANVIL_CHANGED_' + $scheme)
  }
  # A same-appearance update must not add input before the test's sentinel.
  if ($inputStream.ReadByte() -ne 33) { exit 6 }
  [Console]::Write($escape + '[?2031l' + 'ANVIL_WATCH_OFF')
  if ($inputStream.ReadByte() -ne 33) { exit 7 }
  [Console]::Write('ANVIL_WATCH_DONE')
}
