#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive USB flasher for Surface Pro 11 Arch Linux image.
    Lists all connected drives, lets you pick one, then flashes.
    Invoke via flash.bat (auto-elevation) or directly as Administrator.

.EXAMPLE
    # From flash.bat (recommended):
    .\flash.bat

    # Direct (must be in an elevated PowerShell):
    .\scripts\flash-select.ps1
#>

$ErrorActionPreference = "Stop"

# ── Console close-button lock ─────────────────────────────────────────────────
# Disables the X / Alt+F4 close during the flash so a stray click can't kill
# a 5-10 minute write. Re-enabled in the finally block.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ConsoleWindow {
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]  private static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
    [DllImport("user32.dll")]  private static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
    [DllImport("user32.dll")]  private static extern bool DrawMenuBar(IntPtr hWnd);
    public static void DisableCloseButton() {
        IntPtr h = GetConsoleWindow();
        DeleteMenu(GetSystemMenu(h, false), 0xF060, 0x0000);  // SC_CLOSE, MF_BYCOMMAND
        DrawMenuBar(h);
    }
    public static void EnableCloseButton() {
        IntPtr h = GetConsoleWindow();
        GetSystemMenu(h, true);   // revert -> restore default menu
        DrawMenuBar(h);
    }
}
'@

# Belt-and-suspenders: also trap Ctrl+C so a stray ^C doesn't kill the write.
$null = [Console]::CancelKeyPress.Add({
    param($src, $e)
    $e.Cancel = $true
    Write-Host ""
    Write-Host "  *** Ctrl+C ignored during flash. Wait for completion. ***" -ForegroundColor Yellow
    Write-Host ""
})

# Locate image relative to this script's parent directory (repo root)
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$ImagePath = Join-Path $RepoRoot "build\arch-x1p-usb.img"

Clear-Host
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Surface Pro 11 -- Arch Linux USB Flasher " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Image check ────────────────────────────────────────────────────────────────
if (-not (Test-Path $ImagePath)) {
    Write-Host "[!] Image not found:" -ForegroundColor Red
    Write-Host "    $ImagePath" -ForegroundColor Red
    Write-Host ""
    Write-Host "    Build it first (run in WSL as root):"
    Write-Host "      bash scripts/build-usb-image.sh"
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

$ImageSize   = (Get-Item $ImagePath).Length
$ImageSizeGB = [math]::Round($ImageSize / 1GB, 2)
$ImageSizeMB = [math]::Round($ImageSize / 1MB, 1)

Write-Host "  Image : $(Split-Path $ImagePath -Leaf)"
Write-Host "  Size  : ${ImageSizeGB} GB  (${ImageSizeMB} MB)"
Write-Host ""

# ── Drive selection loop ───────────────────────────────────────────────────────
$selectedDisk = $null

while (-not $selectedDisk) {
    Write-Host "Connected drives:" -ForegroundColor Yellow
    Write-Host ""

    $disks = Get-Disk | Sort-Object Number
    foreach ($d in $disks) {
        $sizeGB  = [math]::Round($d.Size / 1GB, 1)
        $isUsb   = $d.BusType -in @("USB", "SD")
        $usbTag  = if ($isUsb) { "  <-- USB/SD" } else { "" }
        $color   = if ($isUsb) { "Green" } else { "DarkGray" }
        Write-Host ("  [{0,2}]  {1,-42} {2,6} GB   {3}{4}" -f
            $d.Number, $d.FriendlyName, $sizeGB, $d.BusType, $usbTag) -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "  R = refresh list    Q = quit" -ForegroundColor DarkGray
    Write-Host ""
    $input = (Read-Host "Enter disk NUMBER to flash").Trim()

    if ($input -match '^[qQ]$') {
        Write-Host "Cancelled." -ForegroundColor Gray
        exit 0
    }
    if ($input -match '^[rR]$') {
        Clear-Host
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  Surface Pro 11 -- Arch Linux USB Flasher " -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Image : $(Split-Path $ImagePath -Leaf)  (${ImageSizeGB} GB)"
        Write-Host ""
        continue
    }
    if ($input -notmatch '^\d+$') {
        Write-Host "[!] Enter a disk number, R, or Q." -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    $disk = Get-Disk -Number ([int]$input) -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-Host "[!] Disk $input not found. Plug in the drive and press R to refresh." -ForegroundColor Red
        Write-Host ""
        continue
    }

    # Safety: non-USB bus type
    if ($disk.BusType -notin @("USB", "SD")) {
        Write-Host ""
        Write-Host "  !! DANGER: Disk $($disk.Number) is $($disk.BusType) -- NOT a USB drive !!" -ForegroundColor Red
        Write-Host "  Flashing an internal disk will destroy your OS." -ForegroundColor Red
        Write-Host ""
        $override = (Read-Host "  Type  OVERRIDE  to proceed anyway (or Enter to go back)").Trim()
        if ($override -ne "OVERRIDE") {
            Write-Host ""
            continue
        }
    }

    # Safety: image must fit on target
    if ($ImageSize -gt $disk.Size) {
        $diskGB = [math]::Round($disk.Size / 1GB, 1)
        Write-Host "[!] Image (${ImageSizeGB} GB) is larger than Disk $($disk.Number) (${diskGB} GB). Use a bigger drive." -ForegroundColor Red
        Write-Host ""
        continue
    }

    $selectedDisk = $disk
}

# ── Confirmation ───────────────────────────────────────────────────────────────
$diskSizeGB = [math]::Round($selectedDisk.Size / 1GB, 1)

Write-Host ""
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "  Target : Disk $($selectedDisk.Number) -- $($selectedDisk.FriendlyName)" -ForegroundColor Yellow
Write-Host "  Size   : ${diskSizeGB} GB  ($($selectedDisk.BusType))" -ForegroundColor Yellow
Write-Host "  Write  : ${ImageSizeMB} MB" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  *** ALL DATA ON DISK $($selectedDisk.Number) WILL BE PERMANENTLY ERASED ***" -ForegroundColor Red
Write-Host ""
$confirm = (Read-Host "  Type  flash  to confirm, or Enter to cancel").Trim()
if ($confirm -ne "flash") {
    Write-Host "Cancelled." -ForegroundColor Gray
    Read-Host "Press Enter to exit"
    exit 0
}

# ── Lock the window and warn ──────────────────────────────────────────────────
Clear-Host
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  *** FLASH STARTING - DO NOT CLOSE THIS WINDOW ***" -ForegroundColor Red
Write-Host "" -ForegroundColor Red
Write-Host "  This takes 5-10 minutes. Closing the window leaves the" -ForegroundColor Red
Write-Host "  USB drive UNUSABLE and you'll have to start over." -ForegroundColor Red
Write-Host "" -ForegroundColor Red
Write-Host "  The X button / Alt+F4 are disabled. Ctrl+C is ignored." -ForegroundColor Yellow
Write-Host "  Just wait for the progress bar to reach 100%." -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

[ConsoleWindow]::DisableCloseButton()
# Closing `try`/`finally` later in this script always re-enables the close
# button, but a `trap` here covers the case where a terminating error fires
# outside the try/finally (e.g. the user closes via Task Manager / a hung
# write that the .NET runtime kills). PowerShell's `trap` runs on every
# terminating error in this script.
trap {
    try { [ConsoleWindow]::EnableCloseButton() } catch {}
    continue
}

# ── Step 1: Offline + clean ────────────────────────────────────────────────────
$DiskNumber = $selectedDisk.Number
Write-Host "[1/3] Preparing Disk $DiskNumber..." -ForegroundColor Cyan

try { Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction SilentlyContinue } catch {}

@"
select disk $DiskNumber
attributes disk clear readonly
clean
offline disk
exit
"@ | diskpart.exe | ForEach-Object {
    if ($_ -match "(DiskPart|cleaned|succeeded|offline|error)") {
        Write-Host "      $_"
    }
}

Start-Sleep -Seconds 2

# ── Step 2: Flash ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/3] Flashing ${ImageSizeMB} MB -> PhysicalDrive${DiskNumber}..." -ForegroundColor Cyan

$diskPath   = "\\.\PhysicalDrive$DiskNumber"
$imgStream  = $null
$diskStream = $null

try {
    $diskStream = [System.IO.FileStream]::new(
        $diskPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite,
        4MB,
        [System.IO.FileOptions]::WriteThrough
    )
    $imgStream = [System.IO.FileStream]::new(
        $ImagePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read,
        4MB
    )

    $buf     = New-Object byte[] (4MB)
    $written = 0
    $chunk   = 0
    $start   = Get-Date

    while ($true) {
        $read = $imgStream.Read($buf, 0, $buf.Length)
        if ($read -eq 0) { break }
        $diskStream.Write($buf, 0, $read)
        $written += $read
        $chunk++

        if ($chunk % 4 -eq 0 -or $written -ge $ImageSize) {
            $pct     = [math]::Min([math]::Round(($written / $ImageSize) * 100, 1), 100)
            $elapsed = ((Get-Date) - $start).TotalSeconds
            $mbps    = if ($elapsed -gt 0) { [math]::Round(($written / 1MB) / $elapsed, 1) } else { 0 }
            Write-Host -NoNewline ("`r      {0,5}%  ({1} / {2} MB)  @ {3} MB/s  " -f
                $pct, [math]::Round($written/1MB), $ImageSizeMB, $mbps)
        }
    }

    $diskStream.Flush()
    $totalSec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    Write-Host ""

    # ── Step 3: Bring disk back online ────────────────────────────────────────
    Write-Host ""
    Write-Host "[3/3] Finalizing..." -ForegroundColor Cyan
    try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue } catch {}

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Flash Complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Written : $([math]::Round($written/1MB)) MB"
    Write-Host "  Time    : ${totalSec}s"
    Write-Host "  Speed   : $([math]::Round(($written/1MB)/$totalSec,1)) MB/s average"
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "    1. Eject the USB drive safely from Windows"
    Write-Host "    2. Insert into Surface Pro 11"
    Write-Host "    3. Hold Volume Down + Power to enter UEFI boot menu"
    Write-Host "    4. Select the USB device"
    Write-Host "============================================" -ForegroundColor Green

} catch {
    Write-Host ""
    Write-Host "[!] Flash failed: $_" -ForegroundColor Red
    Write-Host "    The drive may be in an inconsistent state. Try again." -ForegroundColor Red
    throw
} finally {
    if ($imgStream)  { $imgStream.Close() }
    if ($diskStream) { $diskStream.Close() }
    [ConsoleWindow]::EnableCloseButton()
}

Write-Host ""
Read-Host "Press Enter to exit"
