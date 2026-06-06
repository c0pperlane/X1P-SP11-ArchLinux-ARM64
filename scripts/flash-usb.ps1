#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Flash raw disk image to USB drive for Surface Pro 11.
    Run via flash-usb.bat (double-click) for auto-elevation.
#>

$ErrorActionPreference = "Stop"

# === CONFIG ===
$ImagePath = "$PSScriptRoot\..\build\arch-x1p-usb.img"
$DiskNumber = 1

Write-Host "========================================"
Write-Host "  Surface Pro 11 USB Flasher"
Write-Host "========================================"

if (-not (Test-Path $ImagePath)) {
    Write-Host "[!] Image not found: $ImagePath" -ForegroundColor Red
    Write-Host "    Build it first: bash scripts/build-usb-image.sh"
    exit 1
}

$ImageSize = (Get-Item $ImagePath).Length
$ImageSizeMB = [math]::Round($ImageSize / 1MB, 1)

Write-Host "  Image: $ImagePath"
Write-Host "  Size:  ${ImageSizeMB} MB"

# Get disk info
$Disk = Get-Disk -Number $DiskNumber
$DiskSizeGB = [math]::Round($Disk.Size / 1GB, 1)
Write-Host "  Disk:  $($Disk.FriendlyName)"
Write-Host "  Size:  ${DiskSizeGB} GB"
Write-Host ""

# Safety confirmation
Write-Host "WARNING: THIS WILL ERASE ALL DATA ON THE USB DRIVE!" -ForegroundColor Yellow
$confirm = Read-Host "Type 'flash' to continue"
if ($confirm -ne "flash") {
    Write-Host "Cancelled." -ForegroundColor Red
    exit 0
}

Write-Host ""

# Step 1: Offline the disk
Write-Host "[*] Setting disk offline..."
try {
    Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction SilentlyContinue
    Write-Host "    -> Disk offlined"
} catch {
    Write-Host "    -> Could not offline (continuing anyway)"
}

# Step 2: Clean the disk using diskpart (most reliable)
Write-Host "[*] Cleaning disk with diskpart..."
$diskpartScript = @"
select disk $DiskNumber
attributes disk clear readonly
clean
exit
"@
$diskpartScript | diskpart.exe | ForEach-Object {
    if ($_ -match "(DiskPart|cleaned|succeeded|error)") {
        Write-Host "    diskpart: $_"
    }
}

# Step 3: Open disk for raw writing
Write-Host "[*] Opening disk for raw write..."
$diskPath = "\\.\PhysicalDrive$DiskNumber"

$diskStream = $null
$imgStream = $null

try {
    $diskStream = [System.IO.FileStream]::new($diskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 4MB, [System.IO.FileOptions]::WriteThrough)
    Write-Host "    -> Disk opened"

    # Step 4: Open image and copy
    Write-Host ""
    Write-Host "[*] Flashing ($ImageSizeMB MB)..."
    $imgStream = [System.IO.FileStream]::new($ImagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 4MB)

    $buffer = New-Object byte[] (4MB)
    $written = 0
    $chunkNum = 0
    $startTime = Get-Date

    while ($true) {
        $read = $imgStream.Read($buffer, 0, $buffer.Length)
        if ($read -eq 0) { break }

        $diskStream.Write($buffer, 0, $read)
        $written += $read
        $chunkNum++

        if ($chunkNum % 4 -eq 0 -or $written -ge $ImageSize) {
            $pct = [math]::Min(($written / $ImageSize) * 100, 100)
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            $mbps = if ($elapsed -gt 0) { ($written / 1MB) / $elapsed } else { 0 }
            Write-Host -NoNewline "`r  Progress: $([math]::Round($pct,1))% ($([math]::Round($written/1MB,0)) MB) @ $([math]::Round($mbps,1)) MB/s"
        }
    }

    Write-Host ""
    Write-Host ""
    Write-Host "[*] Syncing..."
    $diskStream.Flush()

    $totalTime = ((Get-Date) - $startTime).TotalSeconds
    Write-Host ""
    Write-Host "========================================"
    Write-Host "  [OK] Flash Complete!" -ForegroundColor Green
    Write-Host "========================================"
    Write-Host "  Written: $([math]::Round($written/1MB,0)) MB"
    Write-Host "  Time:    $([math]::Round($totalTime,1)) seconds"
    Write-Host "  Speed:   $([math]::Round(($written/1MB)/$totalTime,1)) MB/s"
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "    1. Eject USB safely from Windows"
    Write-Host "    2. Insert into Surface Pro 11"
    Write-Host "    3. Hold Volume Down + Power to boot"
    Write-Host "    4. Select USB device in UEFI menu"
    Write-Host "========================================"
} catch {
    Write-Host ""
    Write-Host "[!] FATAL ERROR: $_" -ForegroundColor Red
    throw
} finally {
    if ($imgStream) { $imgStream.Close() }
    if ($diskStream) { $diskStream.Close() }
}
