@echo off
setlocal EnableExtensions

call "%~dp0scripts\msys2-env.cmd"
if errorlevel 1 exit /b 1
rem The dev portable app lives beside the repository.
for %%I in ("%REPO%\..\anvil-portable") do set "DEST=%%~fI"
set "APP=%DEST%\anvil.exe"

cd /d "%REPO%" || exit /b 1

echo Closing running Anvil processes before setup...
call :KillAnvil
if errorlevel 1 exit /b 1

echo === Building Anvil ===
"%BASH%" -lc "zig_dir=$(./scripts/ensure-zig.sh) && export PATH=$zig_dir:$PATH && ./scripts/build.sh -f -P && ./scripts/ensure-luajit-cli.sh"
if errorlevel 1 exit /b 1

echo.
echo === Temporarily removing source-data junctions ===
call :RemoveLink "%DEST%\data\core"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\plugins"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\colors"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\widget"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\treesitter"
if errorlevel 1 exit /b 1

echo.
echo === Installing stripped portable Anvil to %DEST% ===
"%BASH%" -lc "meson install -C build-windows-x86_64 --destdir \"%DEST%\" --strip"
if errorlevel 1 exit /b 1

echo.
echo === Linking editable source data into portable install ===
call :LinkDir "%DEST%\data\core" "%REPO%\data\core"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\plugins" "%REPO%\data\plugins"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\colors" "%REPO%\data\colors"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\widget" "%REPO%\data\widget"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\treesitter" "%REPO%\data\treesitter"
if errorlevel 1 exit /b 1

echo.
echo Dev portable Anvil is ready:
echo   %APP%
echo.
echo Launching Anvil...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPO%\scripts\start-dev-anvil.ps1" -AppRoot "%DEST%"
exit /b %ERRORLEVEL%


:KillAnvil
rem Close all running Anvil processes so installed files are not locked.
taskkill /IM anvil.exe /T >nul 2>nul
taskkill /IM anvil.com /T >nul 2>nul
timeout /T 1 /NOBREAK >nul 2>nul
taskkill /F /IM anvil.exe /T >nul 2>nul
taskkill /F /IM anvil.com /T >nul 2>nul
exit /b 0

:RemoveLink
set "LINK=%~1"
if exist "%LINK%" (
  rem Plain rmdir removes junctions safely. If setup previously failed and this
  rem is a real copied directory, remove its contents too.
  rmdir "%LINK%" 2>nul
  if exist "%LINK%" rmdir /S /Q "%LINK%" 2>nul
  if exist "%LINK%" (
    echo Could not remove %LINK%.
    echo Close Anvil and check that this folder is not in use.
    exit /b 1
  )
)
exit /b 0

:LinkDir
set "LINK=%~1"
set "TARGET=%~2"
if not exist "%TARGET%" (
  echo Link target does not exist: %TARGET%
  exit /b 1
)
if exist "%LINK%" (
  rem First try plain rmdir, which removes junctions safely.
  rmdir "%LINK%" 2>nul
  rem If this was a real installed directory, remove its copied contents.
  if exist "%LINK%" rmdir /S /Q "%LINK%" 2>nul
  if exist "%LINK%" (
    echo Could not remove %LINK%.
    echo Close Anvil and check that this folder is not in use.
    exit /b 1
  )
)
mklink /J "%LINK%" "%TARGET%"
exit /b %ERRORLEVEL%
