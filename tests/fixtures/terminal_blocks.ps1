$e = [char]27
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$blocks = -join (0x2588, 0x2588, 0x2580, 0x2584, 0x259B, 0x259C, 0x2591, 0x2592, 0x2593 | ForEach-Object { [char]$_ })
[Console]::Write($e + '[2J' + $e + '[H' + 'A' + $blocks + 'B')
[Console]::Write($e + '[2;1H' + $e + '[1;2;3;4;7;31m' + [char]0x2588 + $e + '[0m')
[Console]::Write($e + '[3;1H' + [char]0x2588 + [char]0x0301)
[Console]::Write($e + '[4;1HANVIL_BLOCKS_DONE')
