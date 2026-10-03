param([switch]$StayHidden)

$escape = [char]27

function Wait-Briefly([int]$Milliseconds) {
  # Start-Sleep rounds up to the 15.6 ms Windows timer tick.
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.ElapsedMilliseconds -lt $Milliseconds) { }
}

[Console]::Write($escape + '[?25h' + $escape + '[2J' + $escape + '[H' + 'ANVIL_REPAINT_READY')
Start-Sleep -Milliseconds 600

# A shell repaint hides the cursor, draws, then shows it again in a later write.
for ($i = 0; $i -lt 30; $i++) {
  [Console]::Write($escape + '[?25l' + $escape + '[2;1H' + ('x' * ($i + 1)))
  Wait-Briefly 4
  [Console]::Write($escape + '[?25h')
  Start-Sleep -Milliseconds 25
}

if ($StayHidden) {
  [Console]::Write($escape + '[?25l' + $escape + '[4;1HANVIL_REPAINT_HIDDEN')
} else {
  [Console]::Write($escape + '[4;1HANVIL_REPAINT_DONE')
}
Start-Sleep -Milliseconds 1500
