@echo off
setlocal EnableExtensions

set "BASH=C:\msys64\usr\bin\bash.exe"
set "MSYSTEM=MINGW64"
set "CHERE_INVOKING=1"
set "MSYS_ENV=export MSYSTEM=MINGW64 HOME=C:/Users/Darius USERPROFILE=C:/Users/Darius HOMEDRIVE=C: HOMEPATH=/Users/Darius; export PATH=/mingw64/bin:/usr/bin:/bin:$PATH;"

call :UseLayout "D:\Projects\c_projects\anvil-editor" "/d/Projects/c_projects/anvil-editor"
call :UseLayout "C:\Projects\c_projects\anvil-editor" "/c/Projects/c_projects/anvil-editor"
if not defined REPO (
  echo Could not find the Anvil source checkout.
  exit /b 1
)

if not exist "%BASH%" (
  echo MSYS2 bash not found: %BASH%
  exit /b 1
)

cd /d "%REPO%" || exit /b 1
"%BASH%" -lc "%MSYS_ENV% cd %REPO_BASH% && ./scripts/build-standalone-windows.sh"
exit /b %ERRORLEVEL%

:UseLayout
if defined REPO exit /b 0
if exist "%~1\src\api\api.h" (
  set "REPO=%~1"
  set "REPO_BASH=%~2"
)
exit /b 0
