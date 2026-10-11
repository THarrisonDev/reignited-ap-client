@echo off
rem Author: Tim Harrison
rem Created: 2026-10-11
rem Updated: 2026-10-11

rem Run the launcher's built-in installer, then pause so the output stays readable.
"%~dp0srtap_launcher.exe" -install
echo.
pause
