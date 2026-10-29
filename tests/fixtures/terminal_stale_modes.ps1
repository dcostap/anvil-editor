# Turns on the input modes that Pi uses, then ends without cleanup, like a crash.
param([switch]$ModifyOtherKeys)
$escape = [char]27
$keyboard = if ($ModifyOtherKeys) { '[>4;2m' } else { '[>7u' }
[Console]::Write($escape + '[?1000h' + $escape + '[?1002h' + $escape + '[?1003h' +
  $escape + '[?1006h' + $escape + '[?1004h' + $escape + '[?2004h' + $escape + $keyboard +
  $escape + '[?25l' + 'MODES_LEFT_ON')
Stop-Process -Id $PID -Force
