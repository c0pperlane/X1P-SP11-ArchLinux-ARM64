#Requires -RunAsAdministrator
# Auto-flash wrapper - no confirmation prompt, logs to _flash_log_ps.txt

$ErrorActionPreference = "Stop"
$LogFile    = "$PSScriptRoot\_flash_log_ps.txt"
$ImagePath  = "$PSScriptRoot\..\build\arch-x1p-usb.img"
$DiskNumber = 1

# Minimum USB size we expect (MB). A disk smaller than this is almost certainly
# the wrong device (e.g. an SD card or an unrelated removable drive).
$MinDiskSizeMB = 7500   # 7.5 GB - covers an 8 GB image with ~500 MB tolerance

function Log($msg) {
    $msg | Tee-Object -FilePath $LogFile -Append
}

"" | Out-File $LogFile  # clear log

Log "========================================"
Log "  Surface Pro 11 USB Auto-Flasher"
Log "========================================"
Log ""

# ---------------------------------------------------------------------------
# Pre-flight: image file
# ---------------------------------------------------------------------------
if (-not (Test-Path $ImagePath)) {
    Log "[!] Image not found: $ImagePath"
    Log "    Build it first:"
    Log "      wsl bash scripts/build-usb-image.sh"
    exit 1
}

$ImageSize   = (Get-Item $ImagePath).Length
$ImageSizeMB = [math]::Round($ImageSize / 1MB, 1)

Log "  Image : $ImagePath"
Log "  Size  : ${ImageSizeMB} MB"
Log ""

# ---------------------------------------------------------------------------
# Pre-flight: target disk
# ---------------------------------------------------------------------------
try {
    $Disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
} catch {
    Log "[!] Disk $DiskNumber not found."
    Log "    Available disks:"
    Get-Disk | ForEach-Object {
        Log ("    Disk {0}: {1} ({2:N1} GB) - {3}" -f $_.Number, $_.FriendlyName,
             ($_.Size / 1GB), $_.BusType)
    }
    Log ""
    Log "    Set `$DiskNumber at the top of this script to the correct disk number."
    Log "    WARNING: Flashing the wrong disk will destroy data!"
    exit 1
}

$DiskSizeGB  = [math]::Round($Disk.Size / 1GB, 1)
$DiskSizeMB  = [math]::Round($Disk.Size / 1MB, 1)

Log "  Disk  : Disk $DiskNumber - $($Disk.FriendlyName) (${DiskSizeGB} GB, Bus: $($Disk.BusType))"
Log ""

# Guard: disk must be removable or explicitly USB
if ($Disk.BusType -notin @("USB", "SD")) {
    Log "[!] SAFETY ABORT: Disk $DiskNumber has BusType '$($Disk.BusType)'."
    Log "    This script only flashes USB or SD devices."
    exit 1
}

# Guard: disk must be physically present (Online), not a Windows ghost device
if ($Disk.OperationalStatus -ne "Online") {
    Log "[!] Disk $DiskNumber is '$($Disk.OperationalStatus)' - trying to bring online..."
    try {
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop
        Start-Sleep -Seconds 2
        $Disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ($Disk.OperationalStatus -ne "Online") {
            Log "[!] SAFETY ABORT: Disk $DiskNumber is still '$($Disk.OperationalStatus)'."
            Log "    Open Disk Management (diskmgmt.msc) and bring it online manually."
            exit 1
        }
        Log "    Disk is now online."
    } catch {
        Log "[!] Could not bring disk $DiskNumber online: $_"
        Log "    Open Disk Management (diskmgmt.msc) and bring it online manually."
        exit 1
    }
}

# Guard: verify disk is truly accessible by querying its partition style
try {
    $null = Get-Disk -Number $DiskNumber | Get-Partition -ErrorAction SilentlyContinue
} catch {}
# Double-check OperationalStatus is still Online after a brief re-query
Start-Sleep -Milliseconds 500
$DiskRecheck = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
if (-not $DiskRecheck -or $DiskRecheck.OperationalStatus -ne "Online") {
    Log "[!] SAFETY ABORT: Disk $DiskNumber disappeared on recheck - ghost device detected."
    Log "    Plug in the USB drive and try again."
    exit 1
}

# Guard: disk must be at least MinDiskSizeMB
if ($DiskSizeMB -lt $MinDiskSizeMB) {
    Log "[!] SAFETY ABORT: Disk $DiskNumber is only ${DiskSizeMB} MB."
    Log "    Minimum expected size is ${MinDiskSizeMB} MB."
    Log "    Wrong disk selected?"
    exit 1
}

# Guard: image must fit on disk
if ($ImageSize -gt $Disk.Size) {
    Log "[!] SIZE MISMATCH: Image (${ImageSizeMB} MB) is larger than Disk $DiskNumber (${DiskSizeMB} MB)."
    Log "    Use a larger USB drive or rebuild a smaller image."
    exit 1
}

# ---------------------------------------------------------------------------
# Offline the disk
# ---------------------------------------------------------------------------
try { Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction SilentlyContinue } catch {}

# ---------------------------------------------------------------------------
# Clean disk with diskpart
# ---------------------------------------------------------------------------
Log "[*] Cleaning Disk $DiskNumber..."
@"
select disk $DiskNumber
clean
exit
"@ | diskpart.exe | ForEach-Object {
    # Filter out the two expected VDS errors on already-offline disks
    if ($_ -match "^(Microsoft DiskPart version|DISKPART>|DiskPart succeeded|Leaving DiskPart)") {
        Log "    $_"
    }
}

Start-Sleep -Seconds 2

# ---------------------------------------------------------------------------
# Flash
# ---------------------------------------------------------------------------
Log "[*] Flashing ${ImageSizeMB} MB -> PhysicalDrive${DiskNumber}..."
$diskPath = "\\.\PhysicalDrive$DiskNumber"

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
        if ($chunk % 16 -eq 0) {
            $pct  = [math]::Round(($written / $ImageSize) * 100, 1)
            $mbps = [math]::Round(($written / 1MB) / ((Get-Date) - $start).TotalSeconds, 1)
            Log "  $pct% ($([math]::Round($written/1MB)) MB) @ ${mbps} MB/s"
        }
    }

    $diskStream.Flush()
    $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)

    Log ""
    Log "========================================"
    Log "  [OK] Flash Complete!"
    Log "  Written : $([math]::Round($written/1MB)) MB"
    Log "  Time    : ${elapsed}s"
    Log "  Speed   : $([math]::Round(($written/1MB)/$elapsed, 1)) MB/s average"
    Log "========================================"

} catch {
    Log ""
    Log "[!] FLASH ERROR: $_"
    Log "    The USB drive may be in an inconsistent state."
    Log "    Check disk $DiskNumber and retry."
    throw
} finally {
    if ($imgStream)  { $imgStream.Close() }
    if ($diskStream) { $diskStream.Close() }
}
