[Console]::Write('ECHO_READY')
$sequence = 0
while ($true) {
  $key = [Console]::ReadKey($true)
  $sequence++
  [Console]::Write("`r`nACK_${sequence}_$($key.KeyChar)`r`n")
}
