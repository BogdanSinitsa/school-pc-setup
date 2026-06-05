@echo off
setlocal

if /I not "%~1"=="--elevated" (
    fltmc >nul 2>&1
    if errorlevel 1 (
        echo Requesting administrator permission...
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c ""%~f0"" --elevated' -Verb RunAs"
        exit /b
    )
)

cd /d "%~dp0"

echo Running Student desktop setup from:
echo %CD%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configure-StudentDesktop.ps1"
set "SCRIPT_EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%SCRIPT_EXIT_CODE%"=="0" (
    echo Student desktop setup failed with exit code %SCRIPT_EXIT_CODE%.
) else (
    echo Student desktop setup finished.
)
echo.
pause
exit /b %SCRIPT_EXIT_CODE%
