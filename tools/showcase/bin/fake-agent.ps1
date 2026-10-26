# A stand-in for the Pi coding agent, for screenshots. It sends the Terminal title and the program status
# (OSC 7501) that Pi and Anvil's Pi extension send, draws a canned Pi screen, and then waits. It calls no model.
param([Parameter(Mandatory = $true)][string]$Scenario)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$e = [char]27
# Windows PowerShell reads this file as ANSI, so build non-ASCII text from code points.
$pi = [char]0x3C0

# state: idle, working, blocked, done or error. ago: seconds since the state began. step_ago: the same for the step.
$scenarios = @{
  'orbit-claude' = @{ title = "$pi - orbit-api"; model = 'Claude Opus 5.5'; state = 'working'; ago = 1500
    step = 'bash: npm test -- invoice'; step_ago = 131; screen = 'orbit-claude' }
  'orbit-gpt' = @{ title = "$pi - orbit-api"; model = 'GPT-6.1'; state = 'done'; ago = 1080; screen = 'short-done' }
  'ray-claude' = @{ title = "$pi - raytracer"; model = 'Claude Sonnet 5.5'; state = 'working'; ago = 300
    step = 'Thinking'; step_ago = 14; screen = 'short-working' }
  'ray-gpt' = @{ title = "$pi - raytracer"; model = 'GPT-6.1'; state = 'blocked'; ago = 95
    message = 'Run benches?'; screen = 'short-working' }
  'mobile-gpt' = @{ title = "$pi - mobile-app"; model = 'GPT-6.1'; state = 'done'; ago = 1740; screen = 'short-done' }
  'dotfiles-claude' = @{ title = "$pi - dotfiles"; model = 'Claude Opus 5.5'; state = 'done'; ago = 240; screen = 'short-done' }
}
$s = $scenarios[$Scenario]
if (-not $s) { throw "Unknown scenario: $Scenario" }

function Encode([string]$text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
function Report([string]$pairs) { [Console]::Write("$e]7501;$pairs$e\") }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

[Console]::Write("$e]0;$($s.title)$([char]7)")
$root = "state=$($s.state):app=pi:since=$($now - $s.ago)"
if ($s.message) { $root += ":msg=$(Encode $s.message)" }
Report $root
Report "state=idle:id=model:msg=$(Encode $s.model)"
if ($s.step) { Report "state=working:id=step:msg=$(Encode $s.step):since=$($now - $s.step_ago)" }

# Screens use tags for colours: {fg:R,G,B}, {bg:R,G,B}, {b}, {d}, {i} and {/} to reset.
$screen = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "..\screens\$($s.screen).txt")
$screen = $screen.Replace('{model}', $s.model)
$screen = [regex]::Replace($screen, '\{fg:(\d+),(\d+),(\d+)\}', { param($m) "$e[38;2;$($m.Groups[1]);$($m.Groups[2]);$($m.Groups[3])m" })
$screen = [regex]::Replace($screen, '\{bg:(\d+),(\d+),(\d+)\}', { param($m) "$e[48;2;$($m.Groups[1]);$($m.Groups[2]);$($m.Groups[3])m" })
$screen = $screen.Replace('{b}', "$e[1m").Replace('{d}', "$e[2m").Replace('{i}', "$e[3m").Replace('{/}', "$e[0m")
# Pi draws its own input box, so hide the Terminal cursor.
[Console]::Write("$e[?25l$e[2J$e[H" + ($screen -replace "`r?`n", "`r`n"))
while ($true) { Start-Sleep -Seconds 3600 }
