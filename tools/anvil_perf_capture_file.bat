@echo off
rem See "%~dp0PERF_CAPTURE_BENCHMARKS.md" for usage, baselines, and visual regression workflow.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0anvil_perf_capture_file.ps1" %*
exit /b %ERRORLEVEL%
