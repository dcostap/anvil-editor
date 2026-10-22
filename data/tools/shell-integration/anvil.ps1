# Anvil Terminal shell integration for PowerShell.
# Marks each prompt and accepted command with OSC 133. The Terminal Session host
# reports a command that runs inside the shell, such as Start-Sleep, as busy.
# The nonce authenticates the marks: nested shells and TUIs cannot fake them.
param([string]$Nonce)
if ($Global:__AnvilShellIntegration -or -not $Nonce) { return }
$Global:__AnvilShellIntegration = @{
  Nonce = $Nonce
  Prompt = $function:prompt
  ReadLine = $function:PSConsoleHostReadLine
  Running = $false
}

function Global:prompt {
  $success = $Global:?
  $code = $Global:LASTEXITCODE
  $state = $Global:__AnvilShellIntegration
  $e = [char]27; $b = [char]7; $tag = "anvil=$($state.Nonce)"
  $marks = ""
  if ($state.Running) {
    $exit = if ($success) { 0 } elseif ($code) { $code } else { 1 }
    $marks += "$e]133;D;$exit;$tag$b"
    $state.Running = $false
  }
  $marks += "$e]133;A;$tag$b"
  $text = if ($state.Prompt) { & $state.Prompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
  $Global:LASTEXITCODE = $code
  "$marks$text$e]133;B;$tag$b"
}

# Without PSReadLine the shell emits no command marks; the host's process check decides.
if ($Global:__AnvilShellIntegration.ReadLine) {
  function Global:PSConsoleHostReadLine {
    $state = $Global:__AnvilShellIntegration
    $line = & $state.ReadLine
    if ([string]::IsNullOrWhiteSpace($line)) { return $line }
    # OSC titles must not contain terminal controls. Keep the full command in the shell only.
    $title = ($line -replace '[\p{Cc}\p{Zl}\p{Zp}]+', ' ').Trim()
    if ($title.Length -gt 240) {
      $length = if ([char]::IsHighSurrogate($title[239])) { 239 } else { 240 }
      $title = $title.Substring(0, $length) + '...'
    }
    # The host offers the submitted line again if the Terminal Session revives.
    # A longer line would overflow the host's mark buffer, which then ignores the mark.
    $cmdline = if ($line.Length -le 3800) { [Uri]::EscapeDataString($line) } else { "" }
    $cmdline = if ($cmdline -and $cmdline.Length -le 3800) { ";cmdline_url=$cmdline" } else { "" }
    $state.Running = $true
    [Console]::Write("$([char]27)]2;$title$([char]7)$([char]27)]133;C;anvil=$($state.Nonce)$cmdline$([char]7)")
    $line
  }
}
