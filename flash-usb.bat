@echo off
:: Surface Pro 11 USB Reflasher
:: Double-click, click "Yes" on UAC prompt, and it flashes automatically

echo ========================================
echo   Surface Pro 11 USB Reflasher
echo ========================================
echo.

:: Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [*] Requesting administrator privileges...
    echo     Click "Yes" when Windows asks.
    powershell -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

:: We now have admin rights — run the flasher
echo [*] Starting flash...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\flash-usb.ps1"
echo.
pause
