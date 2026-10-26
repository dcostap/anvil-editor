param([Parameter(Mandatory = $true)][string]$AppRoot)
$ErrorActionPreference = 'Stop'
$app = Join-Path ([IO.Path]::GetFullPath($AppRoot)) 'anvil.exe'

if (-not (Test-Path -LiteralPath $app -PathType Leaf)) { throw "Anvil executable not found: $app" }

# Start-Process and CMD start keep the Terminal's kill-on-close Windows job.
# Ask the existing Explorer desktop to launch Anvil outside that job instead.
# Use its desktop object, not a new in-process Shell.Application object.
$windows = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([guid]'9BA05972-F6A8-11CF-A442-00A0C90A8F39'))
$desktopHandle = 0
$desktop = $windows.FindWindowSW(0, 0, 8, [ref]$desktopHandle, 1) # SWC_DESKTOP, SWFO_NEEDDISPATCH
if (-not $desktop) { throw 'Windows Explorer is unavailable. Start Anvil from the desktop.' }
# Keep the caller's working directory. Use Explorer's environment, without build-script variables or inherited pipes.
$desktop.Document.Application.ShellExecute($app, '', (Get-Location).ProviderPath, 'open', 1)
Write-Host 'Started Anvil through Windows Explorer, outside the Terminal process group.'
