@echo off
REM ============================================================
REM  DSH-Pet-Client-Win - one-click install (double-click me)
REM  Equivalent to:
REM    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Start
REM  Output is kept in English on purpose (no code-page surprises).
REM ============================================================
cd /d "%~dp0"
echo.
echo ============================================
echo   DSH-Pet-Client-Win - Install
echo ============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -Start
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
  echo [OK] Install finished.
) else (
  echo [WARN] install.ps1 exited with code %RC% - see output above.
)
echo.
pause
exit /b %RC%
