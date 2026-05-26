@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0anvil_edit_perf_test.ps1" %*
exit /b %ERRORLEVEL%
