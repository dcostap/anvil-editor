[Console]::Write('ECHO_READY')
while ($true) {
  $key = [Console]::ReadKey($true)
  [Console]::Write($key.KeyChar)
}
