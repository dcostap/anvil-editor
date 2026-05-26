@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0anvil_edit_perf_matrix.ps1" %*
exit /b %ERRORLEVEL%
