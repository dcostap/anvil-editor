@echo off
setlocal EnableExtensions

set "REPO=C:\Projects\c_projects\anvil-editor"
set "DEST=C:\Projects\c_projects\anvil-portable"
set "BASH=C:\msys64\usr\bin\bash.exe"
set "APP=%DEST%\anvil.exe"
set "MSYSTEM=MINGW64"
set "CHERE_INVOKING=1"
set "MSYS_ENV=export MSYSTEM=MINGW64 HOME=C:/Users/Darius USERPROFILE=C:/Users/Darius HOMEDRIVE=C: HOMEPATH=/Users/Darius; export PATH=/mingw64/bin:/usr/bin:/bin:$PATH;"

if not exist "%BASH%" (
  echo MSYS2 bash not found: %BASH%
  exit /b 1
)

cd /d "%REPO%" || exit /b 1

echo Close Anvil before continuing. This updates the exe and installed data.
pause

echo.
echo === Temporarily removing source-data junctions ===
call :RemoveLink "%DEST%\data\plugins"
if errorlevel 1 exit /b 1
call :RemoveLink "%DEST%\data\colors"
if errorlevel 1 exit /b 1

echo.
echo === Building Anvil ===
"%BASH%" -lc "%MSYS_ENV% cd /c/Projects/c_projects/anvil-editor && ./scripts/build.sh -f -P"
if errorlevel 1 exit /b 1

echo.
echo === Updating portable Anvil at %DEST% ===
"%BASH%" -lc "%MSYS_ENV% cd /c/Projects/c_projects/anvil-editor && meson install -C build-windows-x86_64 --destdir /c/Projects/c_projects/anvil-portable"
if errorlevel 1 exit /b 1

echo.
echo === Restoring editable source-data junctions ===
call :LinkDir "%DEST%\data\plugins" "%REPO%\data\plugins"
if errorlevel 1 exit /b 1
call :LinkDir "%DEST%\data\colors" "%REPO%\data\colors"
if errorlevel 1 exit /b 1

echo.
echo Updated dev portable Anvil:
echo   %APP%
pause
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
