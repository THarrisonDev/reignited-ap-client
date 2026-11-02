@echo off
rem Author: Tim Harrison
rem Created: 2026-11-01
rem Updated: 2026-11-01

rem Collect the client's support files into one archive, then pause so the path stays readable.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-logs.ps1" %*
echo.
pause
