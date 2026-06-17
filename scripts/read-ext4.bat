@echo off
:: ============================================================
::  read-ext4.bat -- read a file or list a directory on an ext4
::  partition from Windows. Works around the WSL-can't-mount-USB
::  issue by copying the partition to a temp file and having WSL
::  loop-mount that file (which WSL can always do).
::
::  Usage:    read-ext4.bat <linux-path> [disk] [partition]
::
::  Examples:
::    read-ext4.bat /etc/fstab
::    read-ext4.bat /
::    read-ext4.bat /var/log/journal 1 2
::
::  Caches the partition image at:
::    %LOCALAPPDATA%\ext4-cache\disk<N>_part<P>.img
::  (delete it to force a re-read)
::
::  Requires Administrator (UAC will prompt).
:: ============================================================

:: ── Auto-elevate to Administrator ────────────────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

if "%~1"=="" (
    echo Usage: %~nx0 ^<linux-path^> [disk] [partition]
    echo.
    echo   linux-path : absolute path, e.g. /etc/fstab or /var/log/...
    echo   disk       : Windows disk number, default 1
    echo   partition  : partition number on that disk, default 2
    exit /b 1
)

set "DISK=1"
set "PART=2"
if not "%~2"=="" set "DISK=%~2"
if not "%~3"=="" set "PART=%~3"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0read-ext4.ps1" -Path "%~1" -Disk %DISK% -Partition %PART%
