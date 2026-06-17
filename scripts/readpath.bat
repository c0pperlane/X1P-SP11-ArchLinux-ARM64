@echo off
:: ============================================================
::  readpath.bat -- read a file or list a directory
::
::  Thin wrapper around readpath.ps1. Usable from WSL when the
::  target lives on a Windows volume (e.g. USB mounted as E:\)
::  that WSL can't see directly.
::
::  Usage:    readpath.bat <path>
::
::  Accepted path forms:
::    Windows        C:\foo, E:\bar, .\relative
::    WSL /mnt/      /mnt/c/foo, /mnt/e/bar          (-> C:\..., E:\...)
::    UNC            \\wsl$\Distro\path, \\server\share
::
::  Output:
::    File    -> contents (UTF-8, raw)
::    Folder  -> Name | Size | Mode | LastWriteTime
::    Missing -> "Path not found" error, exit 1
:: ============================================================

if "%~1"=="" (
    echo Usage: %~nx0 ^<path^>
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0readpath.ps1" -Path "%~1"
