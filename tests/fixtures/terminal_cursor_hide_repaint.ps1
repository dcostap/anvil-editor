param(
  [Parameter(Mandatory = $true)][string]$ReadySignal,
  [Parameter(Mandatory = $true)][string]$HideSignal,
  [Parameter(Mandatory = $true)][string]$HideWrittenSignal,
  [Parameter(Mandatory = $true)][string]$ShowSignal,
  [Parameter(Mandatory = $true)][string]$ReleaseSignal,
  [switch]$StayHidden
)

$escape = [char]27

function Wait-ForSignal([string]$Path) {
  while (-not [IO.File]::Exists($Path)) {
    Start-Sleep -Milliseconds 10
  }
}

[Console]::Write($escape + '[?25h' + $escape + '[2J' + $escape + '[H' + 'ANVIL_REPAINT_READY')
[Console]::Out.Flush()
[IO.File]::WriteAllText($ReadySignal, 'ready')
Wait-ForSignal $HideSignal

[Console]::Write($escape + '[?25l' + $escape + '[2;1H' + 'x' + 'ANVIL_REPAINT_HIDDEN')
[Console]::Out.Flush()
[IO.File]::WriteAllText($HideWrittenSignal, 'written')

if (-not $StayHidden) {
  Wait-ForSignal $ShowSignal
  [Console]::Write($escape + '[?25h' + $escape + '[4;1H' + 'ANVIL_REPAINT_DONE')
  [Console]::Out.Flush()
}

Wait-ForSignal $ReleaseSignal
