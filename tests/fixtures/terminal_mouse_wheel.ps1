Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WheelConsoleMode {
  [DllImport("kernel32.dll")]
  public static extern IntPtr GetStdHandle(int kind);
  [DllImport("kernel32.dll")]
  public static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
'@

$escape = [char]27
[Console]::Write($escape + '[?1049h' + $escape + '[?7l' + $escape + '[?1000h' +
  $escape + '[?1002h' + $escape + '[?1003h' + $escape + '[?1004h' +
  $escape + '[?1006h' + $escape + '[2J' + $escape + '[H')
# Pi enables mouse reporting before it sets raw console input.
if (-not [WheelConsoleMode]::SetConsoleMode([WheelConsoleMode]::GetStdHandle(-10), 0x0208)) { exit 3 }
[Console]::Write('WHEEL_READY')
$inputStream = [Console]::OpenStandardInput()
do {
  $bytes = New-Object System.Collections.Generic.List[byte]
  do {
    $byte = $inputStream.ReadByte()
    if ($byte -ge 0) { $bytes.Add($byte) }
  } until ($byte -eq 77 -or $byte -lt 0)
  $response = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
} until ($response.Contains($escape + '[<64;') -or $byte -lt 0)
if ($response.EndsWith($escape + '[<64;2;2M')) {
  [Console]::Write('WHEEL_RECEIVED')
} else {
  [Console]::Write('WHEEL_BAD:' + [Convert]::ToBase64String($bytes.ToArray()))
}
Start-Sleep -Seconds 2
