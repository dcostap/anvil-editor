# A terminal program with Pi's identity. It never calls a model or reads user settings.
$ErrorActionPreference = 'Stop'
$id = [guid]::NewGuid().ToString('N')
$launch = @{ id = $id; cwd = (Get-Location).Path; args = @($args) }
$launch | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 (Join-Path $env:ANVIL_TEST_PI_LOG "$id.json")
$esc = [char]27
[Console]::Write("${esc}]7501;state=idle:app=pi${esc}\")
[Console]::WriteLine("PREPARED_PI_READY $id")
while ($null -ne ($line = [Console]::ReadLine())) {
    if ($line -eq 'exit') { break }
    [Console]::WriteLine("PI_INPUT ${id}:$line")
}
[Console]::Write("${esc}]7501;clear=1${esc}\")
