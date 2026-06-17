@echo off
:: ============================================================
::  X1P SP11 Flash - interactive GUI flasher
::
::  Double-click to:
::    1. Request administrator rights (UAC - click Yes)
::    2. Open the GUI: pick a USB/SD disk, check its partition
::       layout, then type FLASH to confirm.
::
::  Your data NVMe: open the tool, select it, click
::  "Mark Protected" ONCE so it can never be flashed.
::
::  Replaces the old CLI flashers (archived in
::  archive\old-flash-scripts.DO-NOT-RUN.zip).
:: ============================================================

setlocal
title X1P SP11 Flash

:: -- Auto-elevate to Administrator --
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  [*] Administrator rights required. Click Yes on the UAC prompt.
    echo.
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\X1P-SP11-Flash.ps1"

if %errorlevel% neq 0 (
    echo.
    echo  [!] Tool exited with error code %errorlevel%.
    pause
)
