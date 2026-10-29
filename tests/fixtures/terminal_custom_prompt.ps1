param([string]$Integration)

function Global:prompt {
  # A custom prompt can opt into mouse input. Cleanup must run before this output.
  [Console]::Write("$([char]27)[?1000h")
  'CUSTOM_PROMPT'
}

. $Integration 'test-prompt'
$Global:LASTEXITCODE = 42
[Console]::WriteLine('BEFORE_PROMPT')
[Console]::WriteLine((prompt))
[Console]::WriteLine("EXIT_CODE=$Global:LASTEXITCODE")
Start-Sleep -Seconds 30
