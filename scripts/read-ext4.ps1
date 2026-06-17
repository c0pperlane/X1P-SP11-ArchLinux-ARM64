<#
.SYNOPSIS
    Read a file or list a directory on an ext4 partition from Windows.
    Reads the partition to a temp file, then has WSL loop-mount it.

.DESCRIPTION
    Works around WSL's inability to mount a USB-attached block device
    directly: copies the partition to a Windows file, then has WSL mount
    the FILE (which WSL can always do).

.PARAMETER Path
    Absolute Linux path. Trailing slash = list directory. / = list root.
.PARAMETER Disk
    Windows disk number (default 1).
.PARAMETER Partition
    Partition number on that disk (default 2 -- where root lives in the SP11 image).

.EXAMPLE
    read-ext4.bat /etc/fstab
    read-ext4.bat /
    read-ext4.bat /var/log/journal/.../system.journal
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,
    [int]$Disk = 1,
    [int]$Partition = 2
)

$ErrorActionPreference = "Stop"

# ── Debug log (so we can see errors from the invisible elevated window) ──────
$DebugLog = Join-Path $env:LOCALAPPDATA "ext4-cache\last_run.log"
$null = New-Item -ItemType Directory -Path (Split-Path $DebugLog) -Force
"" | Out-File $DebugLog
function Dbg($msg) {
    Write-Host $msg
    "[$(Get-Date -Format HH:mm:ss)] $msg" | Out-File $DebugLog -Append
}
Dbg "read-ext4.ps1 starting (pid $PID, admin: $([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator'))"
if (-not $Path.StartsWith('/')) {
    Write-Error "Path must be absolute (start with /). Got: $Path"
    exit 1
}

$part = Get-Partition -DiskNumber $Disk -PartitionNumber $Partition -ErrorAction SilentlyContinue
if (-not $part) {
    Write-Error "Disk $Disk partition $Partition not found."
    Write-Error "  Available partitions on disk ${Disk}:"
    Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Error ("    Part {0}: {1} MB, offset {2} MB" -f $_.PartitionNumber, [math]::Round($_.Size/1MB,1), [math]::Round($_.Offset/1MB,1)) }
    exit 1
}

# ── Cache: read partition to temp file (skip if fresh) ───────────────────────
$tempDir  = Join-Path $env:LOCALAPPDATA "ext4-cache"
$null     = New-Item -ItemType Directory -Path $tempDir -Force
$cacheFile = Join-Path $tempDir "disk${Disk}_part${Partition}.img"
$expectedSize = [int64]$part.Size

$cacheFresh = $false
if (Test-Path $cacheFile) {
    $actual = (Get-Item $cacheFile).Length
    if ($actual -eq $expectedSize) { $cacheFresh = $true }
    else { Remove-Item $cacheFile }
}

if ($cacheFresh) {
    Dbg "[cache] $cacheFile"
} else {
    $sizeMB = [math]::Round($expectedSize / 1MB, 1)
    Dbg "[reading partition] disk $Disk part $Partition -- $sizeMB MB"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $diskPath = "\\.\PhysicalDrive$Disk"
    Dbg "  opening $diskPath for raw read..."
    try {
        $src = [System.IO.FileStream]::new($diskPath, 'Open', 'Read', 'ReadWrite', 4MB)
    } catch {
        Dbg "  FAILED to open $diskPath : $($_.Exception.Message)"
        Dbg "  HRESULT = $($_.Exception.HResult)"
        throw
    }
    Dbg "  opened OK, length = $($src.Length), seeking to offset $($part.Offset)"
    $src.Position = $part.Offset
    $dst = [System.IO.File]::Create($cacheFile)
    Dbg "  cache file created: $cacheFile"
    $buf = New-Object byte[] 4MB
    $total = 0
    $lastReport = 0
    while ($total -lt $expectedSize) {
        $toRead = [Math]::Min($buf.Length, $expectedSize - $total)
        $read = $src.Read($buf, 0, $toRead)
        if ($read -eq 0) { break }
        $dst.Write($buf, 0, $read)
        $total += $read
        if ($sw.Elapsed.TotalSeconds - $lastReport -gt 2) {
            $pct = [math]::Round(($total / $expectedSize) * 100, 1)
            $mbps = [math]::Round($total/1MB / $sw.Elapsed.TotalSeconds, 1)
            Dbg "  {0,5}%  ({1} / {2} MB)  @ {3} MB/s" $pct, ([math]::Round($total/1MB)), $sizeMB, $mbps
            $lastReport = $sw.Elapsed.TotalSeconds
        }
    }
    $src.Close(); $dst.Close()
    Dbg "[read complete] $total bytes in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
}

# ── Mount in WSL ─────────────────────────────────────────────────────────────
$wslPath = $null
try {
    $wslPath = (wsl.exe wslpath -u $cacheFile).Trim()
} catch {}
if (-not $wslPath) {
    # Manual fallback: C:\foo\bar -> /mnt/c/foo/bar
    if ($cacheFile -match '^([A-Z]):\\(.*)$') {
        $wslPath = "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\','/')"
    }
}
if (-not $wslPath) {
    Write-Error "Could not convert $cacheFile to a WSL path"
    exit 1
}

$wslMnt   = "/tmp/ext4mnt_$PID"
$loopFile = "/tmp/ext4loop_$PID"

$mountScript = @"
set -e
mkdir -p '$wslMnt'
LOOP=`$(losetup --show --find '$wslPath')
echo `$LOOP > '$loopFile'
mount `$LOOP '$wslMnt'
"@

$mountOut = wsl.exe -u root bash -c $mountScript 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "WSL mount failed:`n$mountOut"
    exit 1
}

# ── Read or list ─────────────────────────────────────────────────────────────
try {
    if ($Path -eq '/' -or $Path.EndsWith('/')) {
        # Directory listing
        wsl.exe -u root ls -la "$wslMnt$Path" 2>&1
    } else {
        # File read
        wsl.exe -u root cat "$wslMnt$Path" 2>&1
    }
} finally {
    # ── Cleanup: unmount + detach loop ────────────────────────────────────────
    $cleanupScript = @"
LOOP=`$(cat '$loopFile' 2>/dev/null)
if [ -n "`$LOOP" ]; then
    umount '$wslMnt' 2>/dev/null || true
    losetup -d `$LOOP 2>/dev/null || true
    rm -f '$loopFile'
fi
rmdir '$wslMnt' 2>/dev/null || true
"@
    wsl.exe -u root bash -c $cleanupScript 2>&1 | Out-Null
}
