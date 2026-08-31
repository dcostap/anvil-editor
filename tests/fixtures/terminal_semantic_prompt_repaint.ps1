$escape = [char]27
$bell = [char]7
$width = 136

$bytes =
  $escape + '[?2026h' +
  $escape + '[15;1H' + $escape + '[K' + $escape + "[$($width)C" +
  $escape + ']133;A' + $bell +
  $escape + '[48;2;52;53;65m' + "`r" + $escape + '[K' + "`r`n" +
  ' ' + $escape + '[38;2;212;212;212mANVIL_SEMANTIC_MESSAGE' +
  $escape + '[K' + $escape + '[m' + "`r`n" +
  (' ' * $width) +
  $escape + '[17;273H' +
  $escape + ']133;B' + $bell +
  $escape + ']133;C' + $bell +
  $escape + '[?2026l' +
  $escape + '[48;2;52;53;65m' + "`r" + $escape + '[K' +
  $escape + '[20;10H' +
  $escape + ']133;A' + $bell +
  'ANVIL_FRESH_LINE'

[Console]::Write($bytes)
