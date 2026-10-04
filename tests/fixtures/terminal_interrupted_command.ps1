param([string] $CounterPath)
$count = 0
if (Test-Path $CounterPath) { $count = [int](Get-Content -Raw $CounterPath) }
[IO.File]::WriteAllText($CounterPath, [string]($count + 1))
[Console]::WriteLine('ANVIL_INTERRUPTED_COMMAND_RUNNING')
Start-Sleep -Seconds 30
