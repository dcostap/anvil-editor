### TL;DR steps

#### 1. Download PS-SFTA

Open PowerShell and run:

```powershell
cd $env:USERPROFILE
git clone https://github.com/DanysysTeam/PS-SFTA.git
```

If no `git`, download ZIP from:

```text
https://github.com/DanysysTeam/PS-SFTA
```

Extract it to:

```text
C:\Users\<you>\PS-SFTA
```

---

#### 2. Save this script as:

```text
C:\Users\<you>\set-vscode-to-anvil.ps1
```

```powershell
$anvil = 'C:\Projects\c_projects\anvil-portable\anvil.exe'
$sfta = "$env:USERPROFILE\PS-SFTA\SFTA.ps1"
$progId = 'Anvil.Editor'

if (!(Test-Path $anvil)) { throw "Anvil not found: $anvil" }
if (!(Test-Path $sfta)) { throw "PS-SFTA not found: $sfta" }

. $sfta

$base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'

$items = Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
    $uc = Join-Path $_.PSPath 'UserChoice'
    if (Test-Path $uc) {
        $p = Get-ItemProperty $uc -ErrorAction SilentlyContinue
        if ($p.ProgId -match '(?i)(VSCode|VisualStudioCode|Code)') {
            [pscustomobject]@{
                Ext = $_.PSChildName
                OldProgId = $p.ProgId
            }
        }
    }
} | Where-Object {
    $_.Ext -match '^\.[A-Za-z0-9_~+-]+$'
} | Sort-Object Ext -Unique

$backup = Join-Path $env:USERPROFILE ('vscode-associations-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
$items | Export-Csv -NoTypeInformation -Path $backup

Write-Host "Found $($items.Count) VS Code associations"
Write-Host "Backup: $backup"

New-Item -Path "HKCU:\Software\Classes\$progId\shell\open\command" -Force | Out-Null
Set-Item -Path "HKCU:\Software\Classes\$progId\shell\open\command" -Value ('"' + $anvil + '" "%1"')

foreach ($item in $items) {
    Write-Host "Setting $($item.Ext) -> Anvil"
    Register-FTA -ProgramPath $anvil -Extension $item.Ext -ProgId $progId -Icon $anvil | Out-Null
}

Write-Host "Done."
```

---

#### 3. Run it

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\set-vscode-to-anvil.ps1"
```

---

#### 4. Optional: restart Explorer

```powershell
Stop-Process -Name explorer -Force
Start-Process explorer
```

Done.
