@echo off
setlocal
python "%~dp0run_render_perf_gate.py" %*
exit /b %ERRORLEVEL%
