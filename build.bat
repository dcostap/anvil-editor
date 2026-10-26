@echo off
rem Build the standalone Anvil executable: dist\anvil.exe.
setlocal EnableExtensions

call "%~dp0scripts\msys2-env.cmd"
if errorlevel 1 exit /b 1

cd /d "%REPO%" || exit /b 1
"%BASH%" -lc "./scripts/build-standalone-windows.sh"
if errorlevel 1 (
  echo.
  echo The build failed. See the messages above.
  exit /b 1
)
exit /b 0
