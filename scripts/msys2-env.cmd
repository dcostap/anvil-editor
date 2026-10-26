@echo off
rem Prepare MSYS2 for the Anvil build. Callers use "call" so that these variables stay set:
rem   REPO   the repository root
rem   BASH   the MSYS2 bash executable
rem A missing MSYS2 is installed with winget. Missing build packages are installed with pacman.

for %%I in ("%~dp0..") do set "REPO=%%~fI"
if not defined MSYS2_ROOT set "MSYS2_ROOT=C:\msys64"
set "BASH=%MSYS2_ROOT%\usr\bin\bash.exe"
set "MSYSTEM=MINGW64"
set "CHERE_INVOKING=1"

if not exist "%BASH%" (
  echo MSYS2 was not found at %MSYS2_ROOT%. Installing it with winget...
  winget install --id MSYS2.MSYS2 --exact --accept-package-agreements --accept-source-agreements
  if not exist "%BASH%" (
    echo MSYS2 installation failed. Install it from https://www.msys2.org and run this script again.
    echo If MSYS2 is in another folder, set MSYS2_ROOT to that folder.
    exit /b 1
  )
)

set "ANVIL_PACKAGES=git curl unzip patch mingw-w64-x86_64-gcc mingw-w64-x86_64-ninja mingw-w64-x86_64-cmake mingw-w64-x86_64-pkgconf mingw-w64-x86_64-python mingw-w64-x86_64-meson"
"%BASH%" -lc "missing=; for p in $ANVIL_PACKAGES; do pacman -Q $p >/dev/null 2>&1 || missing=\"$missing $p\"; done; command -v meson >/dev/null && missing=${missing/ mingw-w64-x86_64-meson/}; [ -z \"$missing\" ] && exit 0; echo \"Installing MSYS2 packages:$missing\"; pacman -Sy --needed --noconfirm $missing"
if errorlevel 1 (
  echo Could not install the MSYS2 build packages.
  exit /b 1
)
exit /b 0
