param([switch]$OmitEnd, [switch]$ExitAfterUpdate)

$escape = [char]27

[Console]::Write(
  $escape + '[?25h' + $escape + '[2J' + $escape + '[H' +
  'ANVIL_SYNC_READY' + $escape + '[3;1Hprompt' + $escape + '[3;5H'
)
Start-Sleep -Milliseconds 600

[Console]::Write($escape + '[?2026h' + $escape + '[1;60HANVIL_SYNC_DRAWING')
Start-Sleep -Milliseconds 400

$end = if ($OmitEnd) { '' } else { $escape + '[?2026l' }
[Console]::Write($escape + '[1;1HANVIL_SYNC_COMPLETE' + $escape + '[3;5H' + $end)
if (-not $ExitAfterUpdate) {
  Start-Sleep -Milliseconds $(if ($OmitEnd) { 3000 } else { 600 })
}
