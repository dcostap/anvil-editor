@echo off
setlocal EnableExtensions

set "BASH=C:\msys64\usr\bin\bash.exe"
set "MSYSTEM=MINGW64"
set "CHERE_INVOKING=1"
set "MSYS_ENV=export MSYSTEM=MINGW64 HOME=C:/Users/Darius USERPROFILE=C:/Users/Darius HOMEDRIVE=C: HOMEPATH=/Users/Darius; export PATH=/mingw64/bin:/usr/bin:/bin:$PATH;"

call :UseLayout "D:\Projects\c_projects\anvil-editor" "D:\Projects\c_projects\anvil-portable" "/d/Projects/c_projects/anvil-editor" "/d/Projects/c_projects/anvil-portable"
call :UseLayout "C:\Projects\c_projects\anvil-editor" "C:\Projects\c_projects\anvil-portable" "/c/Projects/c_projects/anvil-editor" "/c/Projects/c_projects/anvil-portable"
if not defined REPO (
  echo Could not find Anvil source checkout at either:
  echo   D:\Projects\c_projects\anvil-editor
  echo   C:\Projects\c_projects\anvil-editor
  exit /b 1
)
set "APP=%DEST%\anvil.exe"

if not exist "%BASH%" (
  echo MSYS2 bash not found: %BASH%
  exit /b 1
)

cd /d "%REPO%" || exit /b 1

echo Closing running Anvil processes before setup...
call :KillAnvil
if errorlevel 1 exit /b 1

echo === Building Anvil ===
"%BASH%" -lc "%MSYS_ENV% cd %REPO_BASH% && ./scripts/build.sh -f -P && ./scripts/ensure-luajit-cli.sh"
if errorlevel 1 exit /b 1

echo.
echo === Temporarily removing source-data junctions ===
call :RemoveLink "%DEST%\data\core"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\plugins"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\colors"
call :RemoveLink "%DEST%\data\treesitter"
if errorlevel 1 exit /b 1

echo.
echo === Installing portable Anvil to %DEST% ===
"%BASH%" -lc "%MSYS_ENV% cd %REPO_BASH% && meson install -C build-windows-x86_64 --destdir %DEST_BASH%"
if errorlevel 1 exit /b 1

echo.
echo === Linking editable source data into portable install ===
call :LinkDir "%DEST%\data\core" "%REPO%\data\core"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\plugins" "%REPO%\data\plugins"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\colors" "%REPO%\data\colors"
call :LinkDir "%DEST%\data\treesitter" "%REPO%\data\treesitter"
if errorlevel 1 exit /b 1

echo.
echo Dev portable Anvil is ready:
echo   %APP%
echo.
echo Launching Anvil...
start "Anvil" "%APP%"
exit /b 0

:UseLayout
if defined REPO exit /b 0
if exist "%~1\src\api\api.h" (
  set "REPO=%~1"
  set "DEST=%~2"
  set "REPO_BASH=%~3"
  set "DEST_BASH=%~4"
)
exit /b 0

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
