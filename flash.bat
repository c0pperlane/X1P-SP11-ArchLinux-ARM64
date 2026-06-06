@echo off
:: ============================================================
::  Surface Pro 11 — Arch Linux USB Flasher
::
::  Double-click this file to:
::    1. Request administrator rights
::    2. Show all connected drives
::    3. Let you pick a USB drive by number
::    4. Flash the Arch Linux image to it
::
::  Requires: build\arch-x1p-usb.img  (built via WSL)
:: ============================================================

setlocal
title Surface Pro 11 — USB Flasher

:: ── Auto-elevate to Administrator ────────────────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  [*] Administrator rights required.
    echo      Click Yes on the UAC prompt.
    echo.
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: ── Run the interactive drive selector ───────────────────────────────────────
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\flash-select.ps1"

:: Keep window open after the script finishes (in case it exited with an error)
if %errorlevel% neq 0 (
    echo.
    echo  [!] Script exited with error code %errorlevel%.
    pause
)
