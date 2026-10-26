@echo off
rem Starts the real Pi on one scenario from agents.json: "pi <scenario> <provider/model>".
rem run_showcase.py sets ANVIL_SHOWCASE_PI and points Pi at its canned local model.
cls
set ANVIL_SHOWCASE_AGENT=%1
"%ANVIL_SHOWCASE_PI%" --model %2 --extension "%~dp0..\pi\showcase.cjs"
