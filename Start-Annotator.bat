@echo off
rem Usage: double-click, or drag a protocol .json/.txt file onto this file,
rem        or: Start-Annotator.bat path\to\protocol.json
if "%~1"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Start-Annotator.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Start-Annotator.ps1" -ProtocolSource "%~1"
)
if errorlevel 1 pause
