@echo off
setlocal EnableExtensions

for %%I in ("%~dp0.") do set "REPO=%%~fI"
for %%I in ("%REPO%\..\anvil-portable") do set "DEST=%%~fI"

set "DEBUG_APP=%REPO%\build-windows-x86_64\src\anvil.exe"
set "DEBUG_DATA=%REPO%\build-windows-x86_64\src\data"

if not exist "%DEBUG_APP%" (
  echo Unstripped debug executable not found:
  echo   %DEBUG_APP%
  echo Run update-anvil-dev-build.bat first.
  exit /b 1
)
if not exist "%DEST%\data\core\start.lua" (
  echo Dev portable data not found:
  echo   %DEST%\data
  echo Run setup-anvil-dev.bat first.
  exit /b 1
)

if not exist "%DEBUG_DATA%\core\start.lua" (
  if exist "%DEBUG_DATA%" (
    echo Debug runtime data path exists but is not a valid Anvil data directory:
    echo   %DEBUG_DATA%
    exit /b 1
  )
  mklink /J "%DEBUG_DATA%" "%DEST%\data" >nul
  if errorlevel 1 (
    echo Could not link debug runtime data:
    echo   %DEBUG_DATA% -^> %DEST%\data
    exit /b 1
  )
)

set "ANVIL_USERDIR=%DEST%\user"
echo Launching unstripped debug Anvil:
echo   %DEBUG_APP%
start "Anvil Debug" "%DEBUG_APP%" %*
exit /b 0

