@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0anvil_scroll_perf_test.ps1" %*
exit /b %ERRORLEVEL%
