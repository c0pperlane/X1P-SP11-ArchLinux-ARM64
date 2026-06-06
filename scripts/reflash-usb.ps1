#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-click reflash script for Surface Pro 11 Arch Linux USB image.
    Mounts USB disk into WSL2, flashes with dd, unmounts.
#>

$ErrorActionPreference = "Stop"

# === CONFIG ===
$ImagePath = "$PSScriptRoot\..\build\arch-x1p-usb.img"
$UsbDiskFriendlyName = ""  # Leave empty to auto-detect any USB drive, or set to e.g. "SanDisk" to match by name

# === CHECKS ===
if (-not (Test-Path $ImagePath)) {
    Write-Host "[!] Image not found: $ImagePath" -ForegroundColor Red
    Write-Host "    Run scripts/build-usb-image.sh first."
    exit 1
}

$ImageSizeMB = [math]::Round((Get-Item $ImagePath).Length / 1MB, 1)
Write-Host "========================================"
Write-Host "  Surface Pro 11 USB Reflash"
Write-Host "========================================"
Write-Host "  Image: $ImagePath"
Write-Host "  Size:  ${ImageSizeMB} MB"

# Find the USB disk
$UsbDisk = Get-Disk | Where-Object { $_.FriendlyName -like "*$UsbDiskFriendlyName*" -or $_.BusType -eq "USB" }

if (-not $UsbDisk) {
    Write-Host ""
    Write-Host "[!] No USB disk found. Available disks:" -ForegroundColor Red
    Get-Disk | Select-Object Number, FriendlyName, @{N="SizeGB";E={[math]::Round($_.Size/1GB,1)}}, BusType | Format-Table
    exit 1
}

if ($UsbDisk.Count -gt 1) {
    Write-Host ""
    Write-Host "[!] Multiple USB disks found. Please unplug all but one:" -ForegroundColor Yellow
    $UsbDisk | Select-Object Number, FriendlyName, @{N="SizeGB";E={[math]::Round($_.Size/1GB,1)}} | Format-Table
    exit 1
}

$DiskNumber = $UsbDisk.Number
$DiskSizeGB = [math]::Round($UsbDisk.Size / 1GB, 1)

Write-Host ""
Write-Host "  Target: Disk $DiskNumber — $($UsbDisk.FriendlyName) (${DiskSizeGB} GB)"
Write-Host ""

# Safety confirmation
Write-Host "⚠️  THIS WILL ERASE ALL DATA ON DISK $DiskNumber!" -ForegroundColor Yellow
$confirm = Read-Host "Type 'flash' to continue"
if ($confirm -ne "flash") {
    Write-Host "Cancelled." -ForegroundColor Red
    exit 0
}

# Unmount any existing WSL mounts for this disk first
Write-Host ""
Write-Host "[*] Cleaning up any existing WSL mounts..."
wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>$null

# Mount disk into WSL2 as bare block device
Write-Host "[*] Mounting USB disk into WSL2..."
wsl --mount "\\.\PHYSICALDRIVE$DiskNumber" --bare
if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] Failed to mount disk into WSL2." -ForegroundColor Red
    exit 1
}

# Find the device name in WSL2
Write-Host "[*] Finding WSL2 device name..."
Start-Sleep -Seconds 2

# The mounted disk usually appears as the last sdX device
$WslDevice = wsl -d Ubuntu -u root -- bash -c "lsblk -d -o NAME,SIZE,MODEL | tail -1 | awk '{print \"/dev/\"\$1}'"
$WslDevice = $WslDevice.Trim()

Write-Host "    WSL2 device: $WslDevice"

# Flash with dd
Write-Host ""
Write-Host "[*] Flashing image (this takes ~30-60 seconds)..."
$ddStart = Get-Date

wsl -d Ubuntu -u root -- bash -c "dd if='$(wslpath $ImagePath)' of=$WslDevice bs=4M status=progress conv=fsync"

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[!] dd failed. Attempting cleanup..." -ForegroundColor Red
    wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>$null
    exit 1
}

$ddDuration = (Get-Date) - $ddStart

# Unmount
Write-Host ""
Write-Host "[*] Unmounting from WSL2..."
wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber"

Write-Host ""
Write-Host "========================================"
Write-Host "  ✅ Flash Complete!" -ForegroundColor Green
Write-Host "========================================"
Write-Host "  Duration: $($ddDuration.ToString('mm\:ss'))"
Write-Host "  Disk:     $WslDevice"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Eject USB safely from Windows"
Write-Host "    2. Insert into Surface Pro 11"
Write-Host "    3. Hold Volume Down + Power to boot"
Write-Host "    4. Select USB device in UEFI menu"
Write-Host "========================================"
