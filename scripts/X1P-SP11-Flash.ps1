#Requires -RunAsAdministrator
<#
.SYNOPSIS
    X1P SP11 Flash - interactive GUI flasher with a disk/partition view.

.DESCRIPTION
    MANUAL ONLY. Replaces the archived CLI flashers
    (archive\old-flash-scripts.DO-NOT-RUN.zip).

    Two modes:
      (1) WHOLE-DISK  - wipes the whole selected disk and writes the full
          GPT image. For blank USB sticks. Respects disk-level protection.
      (2) PARTITION   - writes ONLY into target partitions you pick, leaving
          every other partition byte-for-byte untouched. Writes go through a
          per-partition volume handle (\\.\Volume{GUID}); Windows bounds each
          write to that partition's extent, so it is physically impossible to
          reach another partition. No diskpart clean, no PhysicalDrive write,
          no GPT write. Excluded ("locked") partitions show red with a lock
          drawn through them and can never be a target.

    Launch via X1P-SP11-Flash.bat (auto-elevates).
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Crash safety: log unhandled errors and keep the window alive --------------
$GuiLog = Join-Path $PSScriptRoot '_flash_log_gui.txt'
function Write-GuiLog($m) {
    try { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), ($m | Out-String)) | Add-Content $GuiLog -Encoding UTF8 } catch {}
}
'' | Set-Content $GuiLog -ErrorAction SilentlyContinue
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-GuiLog ('ThreadException: ' + ($e.Exception | Format-List * -Force | Out-String))
    [System.Windows.Forms.MessageBox]::Show($e.Exception.ToString(), 'X1P SP11 Flash - error', 'OK', 'Error') | Out-Null
})
[AppDomain]::CurrentDomain.add_UnhandledException({ param($s, $e) Write-GuiLog ('Unhandled: ' + ($e.ExceptionObject | Out-String)) })

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$BuildDir      = Join-Path $RepoRoot 'build'
$ProtectedFile = Join-Path $PSScriptRoot 'protected-disks.txt'      # whole-disk protection
$LockedFile    = Join-Path $PSScriptRoot 'locked-partitions.txt'    # partition exclusions

$SECTOR = 512
$ESP_TYPE   = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
$LINUX_TYPE = '0fc63daf-8483-4772-8e79-3d69d8477de4'

$GptNames = @{
    'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' = 'EFI / FAT32 (ESP)'
    '0fc63daf-8483-4772-8e79-3d69d8477de4' = 'Linux / ext4'
    '0657fd6d-a4ab-43c4-84e5-0933c84b4f4f' = 'Linux swap'
    'e6d6d379-f507-44c2-a23c-238f2a3df928' = 'Linux LVM'
    'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' = 'Windows data (NTFS)'
    'e3c9e316-0b5c-4db8-817d-f92df00215ae' = 'Microsoft reserved'
    'de94bba4-06d1-4d40-a16a-bfd50179d6ac' = 'Windows recovery'
}

$Banner = @'
  __  __ _ ___    ___ ___  _ _
  \ \/ // | _ \  / __| _ \/ / |
   >  < | |  _/  \__ \  _/| | |
  /_/\_\|_|_|    |___/_|  |_|_|
        X 1 P   S P 1 1   F L A S H
'@

# =============================================================================
# Native volume IO - the boundary guarantee lives here. Writing through a
# volume handle is bounded by the OS to that single partition's extent.
# =============================================================================
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VolumeIO {
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3, FILE_FLAG_NO_BUFFERING = 0x20000000, FILE_FLAG_WRITE_THROUGH = 0x80000000;
    const uint FSCTL_LOCK_VOLUME = 0x00090018, FSCTL_UNLOCK_VOLUME = 0x0009001C, FSCTL_DISMOUNT_VOLUME = 0x00090020;
    const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, uint inSz, IntPtr outBuf, uint outSz, out uint ret, IntPtr ov);

    static string Norm(string p) {
        // CreateFile opens the volume DEVICE only without a trailing backslash.
        if (p.EndsWith("\\")) p = p.Substring(0, p.Length - 1);
        return p;
    }
    public static SafeFileHandle OpenRead(string volPath) {
        var h = CreateFileW(Norm(volPath), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("OpenRead failed, win32=" + Marshal.GetLastWin32Error());
        return h;
    }
    public static SafeFileHandle OpenWriteLocked(string volPath) {
        var h = CreateFileW(Norm(volPath), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("OpenWrite failed, win32=" + Marshal.GetLastWin32Error());
        uint r;
        DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
        DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
        return h;
    }
    public static void Unlock(SafeFileHandle h) {
        uint r; DeviceIoControl(h, FSCTL_UNLOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out r, IntPtr.Zero);
    }
    // The OS-reported byte length of the volume/partition extent.
    public static long GetLength(SafeFileHandle h) {
        IntPtr buf = Marshal.AllocHGlobal(8);
        try {
            uint ret;
            if (!DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, buf, 8, out ret, IntPtr.Zero))
                throw new IOException("GET_LENGTH_INFO failed, win32=" + Marshal.GetLastWin32Error());
            return Marshal.ReadInt64(buf);
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

# =============================================================================
# Persistence helpers
# =============================================================================
function Test-TrivialId([string]$Id) {
    if (-not $Id) { return $true }
    $c = ($Id -replace '[^0-9a-zA-Z]', '').ToLower()
    if ($c -eq '' -or $c -match '^0+$' -or $c -match '^f+$') { return $true }
    return $false
}
function Get-DiskIds($Disk) {
    $ids = @()
    foreach ($v in @($Disk.Guid, $Disk.UniqueId, $Disk.SerialNumber)) {
        if ($v) { $t = $v.ToString().Trim().Trim('{', '}').ToLower(); if (-not (Test-TrivialId $t)) { $ids += $t } }
    }
    return ($ids | Select-Object -Unique)
}
function Get-FileTokens($Path) {
    if (-not (Test-Path $Path)) { return @() }
    $tokens = @()
    foreach ($line in (Get-Content $Path)) {
        $clean = ($line -replace '#.*$', '').Trim()
        if ($clean -eq '') { continue }
        foreach ($tok in ($clean -split '[|\s]+')) {
            $t = $tok.Trim().Trim('{', '}').ToLower()
            if (-not (Test-TrivialId $t)) { $tokens += $t }
        }
    }
    return ($tokens | Select-Object -Unique)
}
function Add-FileLine($Path, [string[]]$Ids, [string]$Label, [string[]]$Header) {
    if (-not $Ids -or $Ids.Count -eq 0) { return $false }
    if (-not (Test-Path $Path)) { ($Header + '') | Set-Content $Path -Encoding ASCII }
    ('{0}    # {1}' -f ($Ids -join ' | '), $Label) | Add-Content $Path -Encoding ASCII
    return $true
}
function Get-ProtectedTokens { Get-FileTokens $ProtectedFile }
function Add-ProtectedIds([string[]]$Ids, [string]$Label) {
    Add-FileLine $ProtectedFile $Ids $Label @(
        '# X1P SP11 Flash - protected disks (gitignored, never committed).',
        '# Disks matching ANY of these ids can NEVER be whole-disk flashed.')
}
function Get-LockedPartGuids { Get-FileTokens $LockedFile }
function Add-LockedPart([string]$Guid, [string]$Label) {
    Add-FileLine $LockedFile @($Guid) $Label @(
        '# X1P SP11 Flash - excluded/locked partitions (gitignored).',
        '# Partitions matching these GUIDs can NEVER be a flash target.')
}
function Remove-LockedPart([string]$Guid) {
    if (-not (Test-Path $LockedFile)) { return }
    $g = $Guid.Trim().Trim('{', '}').ToLower()
    # Keep comments/blanks; drop any data line whose token set contains the guid.
    $kept = Get-Content $LockedFile | Where-Object {
        if ($_ -match '^\s*#' -or $_.Trim() -eq '') { return $true }
        $toks = (($_ -replace '#.*$', '').Trim() -split '[|\s]+') | ForEach-Object { $_.Trim().Trim('{', '}').ToLower() }
        return (-not ($toks -contains $g))
    }
    $kept | Set-Content $LockedFile -Encoding ASCII
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# =============================================================================
# Parse the image's own GPT to find the ESP and ext4 partition byte ranges.
# =============================================================================
function Get-ImagePartitions([string]$ImgPath) {
    $fs = [System.IO.File]::OpenRead($ImgPath)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 1 * $SECTOR
        $hdr = $br.ReadBytes(92)
        if ([System.Text.Encoding]::ASCII.GetString($hdr, 0, 8) -ne 'EFI PART') {
            throw 'Image has no GPT (not a whole-disk image?).'
        }
        $entryLBA   = [BitConverter]::ToUInt64($hdr, 72)
        $numEntries = [BitConverter]::ToUInt32($hdr, 80)
        $entrySize  = [BitConverter]::ToUInt32($hdr, 84)
        $parts = @()
        for ($i = 0; $i -lt $numEntries; $i++) {
            $fs.Position = [int64]$entryLBA * $SECTOR + $i * $entrySize
            $e = $br.ReadBytes([int]$entrySize)
            $gb = New-Object byte[] 16; [Array]::Copy($e, 0, $gb, 0, 16)
            $type = ([guid]::new($gb)).ToString().ToLower()
            if ($type -eq '00000000-0000-0000-0000-000000000000') { continue }
            $first = [BitConverter]::ToUInt64($e, 32)
            $last  = [BitConverter]::ToUInt64($e, 40)
            $parts += [pscustomobject]@{
                Type   = $type
                Offset = [int64]$first * $SECTOR
                Size   = [int64]($last - $first + 1) * $SECTOR
            }
        }
        return $parts
    } finally { $fs.Close() }
}

# =============================================================================
# Disk / partition inventory
# =============================================================================
function Get-Inventory {
    $protected = Get-ProtectedTokens
    $locked    = Get-LockedPartGuids
    $result = @()
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        $isUsb = $d.BusType -in @('USB', 'SD')
        $ids   = Get-DiskIds $d
        $isProt = $false; foreach ($id in $ids) { if ($protected -contains $id) { $isProt = $true; break } }
        $parts = @()
        foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)) {
            $gpt = ''; if ($p.GptType) { $gpt = $p.GptType.Trim('{', '}').ToLower() }
            $pguid = ''; if ($p.Guid) { $pguid = $p.Guid.Trim('{', '}').ToLower() }
            $vol = $p | Get-Volume -ErrorAction SilentlyContinue
            $fsName = if ($vol -and $vol.FileSystem) { $vol.FileSystem }
                      elseif ($GptNames.ContainsKey($gpt)) { $GptNames[$gpt] } else { 'RAW/empty' }
            $label = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { '' }
            $volPath = ($p.AccessPaths | Where-Object { $_ -match 'Volume\{' } | Select-Object -First 1)
            $parts += [pscustomobject]@{
                Kind    = 'part'
                Disk    = $d.Number
                Number  = $p.PartitionNumber
                Offset  = $p.Offset
                Size    = $p.Size
                Fs      = $fsName
                Label   = $label
                Letter  = $p.DriveLetter
                Gpt     = $gpt
                Guid    = $pguid
                VolPath = $volPath
                Locked  = ($pguid -ne '' -and ($locked -contains $pguid))
            }
        }
        $result += [pscustomobject]@{
            Kind       = 'disk'
            Number     = $d.Number
            Name       = $d.FriendlyName
            Size       = $d.Size
            BusType    = $d.BusType
            Ids        = $ids
            IsUsb      = $isUsb
            Protected  = $isProt
            Status     = $d.OperationalStatus
            Partitions = $parts
        }
    }
    return $result
}

# =============================================================================
# Form
# =============================================================================
$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'X1P SP11 Flash'
$form.Size          = New-Object System.Drawing.Size(900, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = [System.Drawing.Color]::FromArgb(24, 24, 28)
$form.ForeColor     = [System.Drawing.Color]::Gainsboro
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

$lblBanner          = New-Object System.Windows.Forms.Label
$lblBanner.Text     = $Banner
$lblBanner.Font     = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$lblBanner.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 160)
$lblBanner.Size     = New-Object System.Drawing.Size(870, 100)
$lblBanner.Location = New-Object System.Drawing.Point(10, 6)
$form.Controls.Add($lblBanner)

# --- Mode selector ---
$grpMode            = New-Object System.Windows.Forms.GroupBox
$grpMode.Text       = 'Mode'
$grpMode.ForeColor  = [System.Drawing.Color]::Gainsboro
$grpMode.Location   = New-Object System.Drawing.Point(12, 108)
$grpMode.Size       = New-Object System.Drawing.Size(540, 46)
$form.Controls.Add($grpMode)

$rbWhole            = New-Object System.Windows.Forms.RadioButton
$rbWhole.Text       = '(1) Whole-disk flash  (erases the entire disk)'
$rbWhole.Location   = New-Object System.Drawing.Point(12, 18)
$rbWhole.Size       = New-Object System.Drawing.Size(280, 22)
$rbWhole.Checked    = $true
$grpMode.Controls.Add($rbWhole)

$rbPart             = New-Object System.Windows.Forms.RadioButton
$rbPart.Text        = '(2) Partition flash  (targets only)'
$rbPart.Location    = New-Object System.Drawing.Point(300, 18)
$rbPart.Size        = New-Object System.Drawing.Size(230, 22)
$grpMode.Controls.Add($rbPart)

# --- Image selector ---
$lblImg             = New-Object System.Windows.Forms.Label
$lblImg.Text        = 'Image:'
$lblImg.Location    = New-Object System.Drawing.Point(12, 162)
$lblImg.Size        = New-Object System.Drawing.Size(50, 22)
$form.Controls.Add($lblImg)

$cmbImg             = New-Object System.Windows.Forms.ComboBox
$cmbImg.Location    = New-Object System.Drawing.Point(64, 159)
$cmbImg.Size        = New-Object System.Drawing.Size(710, 24)
$cmbImg.DropDownStyle = 'DropDownList'
$cmbImg.BackColor   = [System.Drawing.Color]::FromArgb(40, 40, 46)
$cmbImg.ForeColor   = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($cmbImg)

$btnImgRefresh          = New-Object System.Windows.Forms.Button
$btnImgRefresh.Text     = 'Browse...'
$btnImgRefresh.Location = New-Object System.Drawing.Point(782, 158)
$btnImgRefresh.Size     = New-Object System.Drawing.Size(86, 25)
$form.Controls.Add($btnImgRefresh)

# --- Tree ---
$tree               = New-Object System.Windows.Forms.TreeView
$tree.Location      = New-Object System.Drawing.Point(12, 194)
$tree.Size          = New-Object System.Drawing.Size(560, 420)
$tree.Font          = New-Object System.Drawing.Font('Consolas', 9)
$tree.BackColor     = [System.Drawing.Color]::FromArgb(16, 16, 20)
$tree.ForeColor     = [System.Drawing.Color]::Gainsboro
$tree.HideSelection = $false
$tree.DrawMode      = [System.Windows.Forms.TreeViewDrawMode]::OwnerDrawText
$tree.ItemHeight    = 22
$form.Controls.Add($tree)

# --- Right panel: info + actions ---
$lblInfo            = New-Object System.Windows.Forms.Label
$lblInfo.Location   = New-Object System.Drawing.Point(584, 194)
$lblInfo.Size       = New-Object System.Drawing.Size(296, 150)
$lblInfo.Font       = New-Object System.Drawing.Font('Consolas', 9)
$lblInfo.Text       = 'Select a disk or partition.'
$form.Controls.Add($lblInfo)

# Whole-disk action buttons
$btnProtect         = New-Object System.Windows.Forms.Button
$btnProtect.Text    = 'Mark disk Protected (never whole-flash)'
$btnProtect.Location = New-Object System.Drawing.Point(584, 350)
$btnProtect.Size    = New-Object System.Drawing.Size(296, 28)
$form.Controls.Add($btnProtect)

# Partition action buttons
$btnLock            = New-Object System.Windows.Forms.Button
$btnLock.Text       = 'Exclude / LOCK partition'
$btnLock.Location   = New-Object System.Drawing.Point(584, 350)
$btnLock.Size       = New-Object System.Drawing.Size(296, 26)
$btnLock.Visible    = $false
$form.Controls.Add($btnLock)

$btnUnlock          = New-Object System.Windows.Forms.Button
$btnUnlock.Text     = 'Unlock partition'
$btnUnlock.Location = New-Object System.Drawing.Point(584, 380)
$btnUnlock.Size     = New-Object System.Drawing.Size(296, 26)
$btnUnlock.Visible  = $false
$form.Controls.Add($btnUnlock)

$btnTgtRoot         = New-Object System.Windows.Forms.Button
$btnTgtRoot.Text    = 'Set as ROOT (ext4) target'
$btnTgtRoot.Location = New-Object System.Drawing.Point(584, 412)
$btnTgtRoot.Size    = New-Object System.Drawing.Size(296, 26)
$btnTgtRoot.Visible = $false
$form.Controls.Add($btnTgtRoot)

$btnTgtEsp          = New-Object System.Windows.Forms.Button
$btnTgtEsp.Text     = 'Set as ESP (FAT32) target'
$btnTgtEsp.Location = New-Object System.Drawing.Point(584, 440)
$btnTgtEsp.Size     = New-Object System.Drawing.Size(296, 26)
$btnTgtEsp.Visible  = $false
$form.Controls.Add($btnTgtEsp)

$btnTgtClear        = New-Object System.Windows.Forms.Button
$btnTgtClear.Text   = 'Clear target role'
$btnTgtClear.Location = New-Object System.Drawing.Point(584, 468)
$btnTgtClear.Size   = New-Object System.Drawing.Size(296, 26)
$btnTgtClear.Visible = $false
$form.Controls.Add($btnTgtClear)

$btnSetTypes        = New-Object System.Windows.Forms.Button
$btnSetTypes.Text   = 'Set GPT types on targets (ESP/Linux)'
$btnSetTypes.Location = New-Object System.Drawing.Point(584, 496)
$btnSetTypes.Size   = New-Object System.Drawing.Size(296, 26)
$btnSetTypes.Visible = $false
$form.Controls.Add($btnSetTypes)

$lblLegend          = New-Object System.Windows.Forms.Label
$lblLegend.Location = New-Object System.Drawing.Point(584, 526)
$lblLegend.Size     = New-Object System.Drawing.Size(296, 92)
$lblLegend.Font     = New-Object System.Drawing.Font('Consolas', 8)
$lblLegend.ForeColor = [System.Drawing.Color]::Silver
$lblLegend.Text     = @"
Legend (partition mode):
  [#=]  red, struck  = LOCKED (never written)
  ESP>  green        = ESP target
  ROOT> green        = ext4 root target
  grey               = ignored (untouched)
Lock your data partitions first.
"@
$form.Controls.Add($lblLegend)

# --- Refresh + Flash + progress ---
$btnRefresh         = New-Object System.Windows.Forms.Button
$btnRefresh.Text    = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(12, 622)
$btnRefresh.Size    = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($btnRefresh)

$btnFlash           = New-Object System.Windows.Forms.Button
$btnFlash.Text      = 'FLASH'
$btnFlash.Location  = New-Object System.Drawing.Point(140, 622)
$btnFlash.Size      = New-Object System.Drawing.Size(432, 34)
$btnFlash.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnFlash.BackColor = [System.Drawing.Color]::FromArgb(120, 30, 30)
$btnFlash.ForeColor = [System.Drawing.Color]::White
$btnFlash.Enabled   = $false
$form.Controls.Add($btnFlash)

$progress           = New-Object System.Windows.Forms.ProgressBar
$progress.Location  = New-Object System.Drawing.Point(584, 622)
$progress.Size      = New-Object System.Drawing.Size(296, 16)
$form.Controls.Add($progress)

$status             = New-Object System.Windows.Forms.Label
$status.Location    = New-Object System.Drawing.Point(12, 662)
$status.Size        = New-Object System.Drawing.Size(868, 24)
$status.Font        = New-Object System.Drawing.Font('Consolas', 9)
$status.Text        = 'Ready.'
$form.Controls.Add($status)

# =============================================================================
# Session target roles: partition GUID -> 'ESP' | 'ROOT'
# =============================================================================
$script:Roles     = @{}
$script:Inventory = @()

# =============================================================================
# Image discovery
# =============================================================================
function Update-Images {
    $cmbImg.Items.Clear()
    if (Test-Path $BuildDir) {
        Get-ChildItem (Join-Path $BuildDir '*.img') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $cmbImg.Items.Add(('{0}   ({1})   [{2}]' -f $_.Name, (Format-Size $_.Length), $_.FullName)) | Out-Null }
    }
    if ($cmbImg.Items.Count -gt 0) { $cmbImg.SelectedIndex = 0 }
    else { $cmbImg.Items.Add('(no .img in build\ - build it first, or Browse...)') | Out-Null; $cmbImg.SelectedIndex = 0 }
}
function Get-SelectedImagePath {
    $t = [string]$cmbImg.SelectedItem
    if ($t -match '\[(.+)\]$') { return $Matches[1] }
    return $null
}

# =============================================================================
# Tree population
# =============================================================================
function Update-Tree {
    $tree.BeginUpdate()
    $tree.Nodes.Clear()
    $script:Inventory = Get-Inventory
    foreach ($d in $script:Inventory) {
        $tags = @()
        if (-not $d.IsUsb) { $tags += 'INTERNAL' }
        if ($d.Protected)  { $tags += 'PROTECTED' }
        $tagStr = if ($tags.Count) { '  [' + ($tags -join '/') + ']' } else { '' }
        $txt = 'Disk {0}  {1}  ({2}, {3}){4}' -f $d.Number, $d.Name, (Format-Size $d.Size), $d.BusType, $tagStr
        $node = New-Object System.Windows.Forms.TreeNode($txt)
        $node.Tag = $d
        if ($d.Partitions.Count -eq 0) {
            $sub = New-Object System.Windows.Forms.TreeNode('(no partitions / unallocated)')
            $node.Nodes.Add($sub) | Out-Null
        } else {
            foreach ($p in $d.Partitions) {
                $lbl = if ($p.Label) { '"{0}"' -f $p.Label } else { '-' }
                $ltr = if ($p.Letter) { '({0}:)' -f $p.Letter } else { '' }
                $ptxt = 'Part {0}:  {1,-10}  {2,-20}  {3} {4}' -f $p.Number, (Format-Size $p.Size), $p.Fs, $lbl, $ltr
                $sub = New-Object System.Windows.Forms.TreeNode($ptxt)
                $sub.Tag = $p
                $node.Nodes.Add($sub) | Out-Null
            }
        }
        $tree.Nodes.Add($node) | Out-Null
        $node.Expand()
    }
    $tree.EndUpdate()
}

function Get-SelectedNodeInfo { if ($tree.SelectedNode) { return $tree.SelectedNode.Tag } return $null }
function Get-SelectedDisk {
    $n = $tree.SelectedNode
    if (-not $n) { return $null }
    while ($n.Parent) { $n = $n.Parent }
    return $n.Tag
}

# =============================================================================
# Owner-draw: locked partitions are red with a lock + a line struck through.
# =============================================================================
$tree.Add_DrawNode({
    param($s, $e)
  try {
    $g = $e.Graphics
    $node = $e.Node
    $info = $node.Tag
    $b = $e.Bounds
    if ($b.Width -le 0) { $e.DrawDefault = $true; return }
    $selected = (($e.State -band [System.Windows.Forms.TreeNodeStates]::Selected) -ne 0)
    $bg = if ($selected) { [System.Drawing.Color]::FromArgb(55, 55, 78) } else { $tree.BackColor }
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $bg), $b)

    $partMode = $rbPart.Checked
    $color = [System.Drawing.Color]::Gainsboro
    $prefix = ''
    $locked = $false
    if ($info -and $info.Kind -eq 'disk') {
        if ($info.Protected)   { $color = [System.Drawing.Color]::FromArgb(255, 140, 140) }
        elseif (-not $info.IsUsb) { $color = [System.Drawing.Color]::FromArgb(150, 150, 150) }
        else { $color = [System.Drawing.Color]::FromArgb(120, 220, 160) }
    } elseif ($info -and $info.Kind -eq 'part') {
        $role = $script:Roles[$info.Guid]
        if ($partMode -and $info.Locked) {
            $locked = $true; $color = [System.Drawing.Color]::FromArgb(240, 90, 90); $prefix = '[#=] '
        } elseif ($partMode -and $role -eq 'ROOT') {
            $color = [System.Drawing.Color]::FromArgb(120, 230, 120); $prefix = 'ROOT> '
        } elseif ($partMode -and $role -eq 'ESP') {
            $color = [System.Drawing.Color]::FromArgb(120, 230, 120); $prefix = 'ESP>  '
        } elseif ($partMode) {
            $color = [System.Drawing.Color]::FromArgb(150, 150, 150)
        } else {
            $color = [System.Drawing.Color]::Gainsboro
        }
    } else {
        $color = [System.Drawing.Color]::FromArgb(150, 150, 150)
    }

    $font = $tree.Font
    $text = $prefix + $node.Text
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $b, $color,
        ([System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))

    if ($locked) {
        # draw a red line straight through the middle (the "lock through")
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(240, 90, 90)), 2
        $midY = $b.Top + [int]($b.Height / 2)
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font)
        $g.DrawLine($pen, $b.Left, $midY, $b.Left + $sz.Width, $midY)
        # tiny padlock glyph at far left of the strike
        $lx = $b.Left + 2; $ly = $b.Top + 4
        $g.DrawArc($pen, $lx + 2, $ly, 6, 8, 180, 180)            # shackle
        $g.DrawRectangle($pen, $lx, $ly + 4, 10, 9)               # body
        $pen.Dispose()
    }
    if ($selected) {
        $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, 120, 160))), $b.Left, $b.Top, $b.Width - 1, $b.Height - 1)
    }
  } catch { Write-GuiLog ('DrawNode: ' + ($_ | Out-String)); try { $e.DrawDefault = $true } catch {} }
})

# =============================================================================
# Selection -> info + button gating
# =============================================================================
function Update-Buttons {
    $partMode = $rbPart.Checked
    $btnProtect.Visible = -not $partMode
    foreach ($btn in @($btnLock, $btnUnlock, $btnTgtRoot, $btnTgtEsp, $btnTgtClear, $btnSetTypes)) { $btn.Visible = $partMode }

    $info = Get-SelectedNodeInfo
    $img = Get-SelectedImagePath
    $imgOk = $img -and (Test-Path $img)

    if (-not $partMode) {
        $d = Get-SelectedDisk
        $btnFlash.Text = 'FLASH (whole disk)'
        $btnFlash.Enabled = ($d -and $d.IsUsb -and -not $d.Protected -and $imgOk)
        $btnProtect.Enabled = ($d -ne $null)
    } else {
        $isPart = ($info -and $info.Kind -eq 'part')
        $btnLock.Enabled    = ($isPart -and -not $info.Locked)
        $btnUnlock.Enabled  = ($isPart -and $info.Locked)
        $btnTgtRoot.Enabled = ($isPart -and -not $info.Locked)
        $btnTgtEsp.Enabled  = ($isPart -and -not $info.Locked)
        $btnTgtClear.Enabled = ($isPart -and $script:Roles.ContainsKey($info.Guid))
        # flash enabled if at least a ROOT target is set and image ok
        $hasRoot = ($script:Roles.Values -contains 'ROOT')
        $btnFlash.Text = 'FLASH (partition targets)'
        $btnFlash.Enabled = ($hasRoot -and $imgOk)
        $btnSetTypes.Enabled = ($script:Roles.Count -gt 0)
    }
}

$tree.Add_AfterSelect({
    $info = Get-SelectedNodeInfo
    if (-not $info) { return }
    $lines = @()
    if ($info.Kind -eq 'disk') {
        $lines += 'Disk {0}: {1}' -f $info.Number, $info.Name
        $lines += 'Size {0}  Bus {1}  {2}' -f (Format-Size $info.Size), $info.BusType, $info.Status
        $lines += if ($info.Protected) { '** PROTECTED **' } elseif (-not $info.IsUsb) { '** INTERNAL **' } else { 'USB/SD' }
    } else {
        $role = $script:Roles[$info.Guid]
        $lines += 'Disk {0} Part {1}' -f $info.Disk, $info.Number
        $lines += 'Size   : {0}' -f (Format-Size $info.Size)
        $lines += 'Offset : {0:N0}' -f $info.Offset
        $lines += 'FS     : {0}' -f $info.Fs
        $lines += 'Label  : {0}' -f $(if ($info.Label) { $info.Label } else { '-' })
        $lines += 'Letter : {0}' -f $(if ($info.Letter) { $info.Letter } else { '-' })
        $lines += 'PartGUID: {0}' -f $info.Guid
        $lines += 'State  : {0}' -f $(if ($info.Locked) { 'LOCKED' } elseif ($role) { "TARGET=$role" } else { 'ignored' })
    }
    $lblInfo.Text = $lines -join "`r`n"
    Update-Buttons
})

# =============================================================================
# Partition action buttons
# =============================================================================
$btnLock.Add_Click({
    $info = Get-SelectedNodeInfo
    if (-not ($info -and $info.Kind -eq 'part')) { return }
    if ($info.Guid -eq '') { [System.Windows.Forms.MessageBox]::Show('Partition has no GUID; cannot lock.', 'No GUID', 'OK', 'Warning') | Out-Null; return }
    [void](Add-LockedPart $info.Guid ('Disk{0} Part{1} {2} {3}' -f $info.Disk, $info.Number, $info.Fs, $info.Label))
    $script:Roles.Remove($info.Guid)
    Update-Tree; $status.Text = 'Partition locked (excluded). It can never be a flash target.'
})
$btnUnlock.Add_Click({
    $info = Get-SelectedNodeInfo
    if (-not ($info -and $info.Kind -eq 'part')) { return }
    $r = [System.Windows.Forms.MessageBox]::Show('Unlock this partition? It will become eligible as a target again.', 'Unlock', 'YesNo', 'Warning')
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Remove-LockedPart $info.Guid; Update-Tree; $status.Text = 'Partition unlocked.' }
})
function Set-Target([string]$RoleName) {
    $info = Get-SelectedNodeInfo
    if (-not ($info -and $info.Kind -eq 'part')) { return }
    if ($info.Locked) { [System.Windows.Forms.MessageBox]::Show('This partition is LOCKED. Unlock it first (not recommended for data).', 'Locked', 'OK', 'Warning') | Out-Null; return }
    if ($info.Letter) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            ("This partition has drive letter {0}: and filesystem {1}." -f $info.Letter, $info.Fs) + "`r`nThat usually means it holds data. Use it as a target anyway?",
            'Has drive letter', 'YesNo', 'Warning')
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    # clear any other partition holding the same role
    foreach ($k in @($script:Roles.Keys)) { if ($script:Roles[$k] -eq $RoleName) { $script:Roles.Remove($k) } }
    $script:Roles[$info.Guid] = $RoleName
    Update-Tree; Update-Buttons
    $status.Text = "Set Disk$($info.Disk) Part$($info.Number) as $RoleName target."
}
$btnTgtRoot.Add_Click({ Set-Target 'ROOT' })
$btnTgtEsp.Add_Click({ Set-Target 'ESP' })
$btnTgtClear.Add_Click({
    $info = Get-SelectedNodeInfo
    if ($info -and $script:Roles.ContainsKey($info.Guid)) { $script:Roles.Remove($info.Guid); Update-Tree; Update-Buttons; $status.Text = 'Target role cleared.' }
})

# Set the GPT type of the current ESP/ROOT targets WITHOUT writing data, so an
# already-flashed disk becomes bootable. Only touches the targets' type field.
$btnSetTypes.Add_Click({
    if ($script:Roles.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Set an ESP and/or ROOT target first.', 'No targets', 'OK', 'Warning') | Out-Null; return }
    $allParts = Get-Inventory | ForEach-Object { $_.Partitions } | Where-Object { $_ }
    $locked = Get-LockedPartGuids
    $todo = @()
    foreach ($kv in $script:Roles.GetEnumerator()) {
        $tp = $allParts | Where-Object { $_.Guid -eq $kv.Key } | Select-Object -First 1
        if (-not $tp) { continue }
        if ($locked -contains $tp.Guid) { [System.Windows.Forms.MessageBox]::Show("$($kv.Value) target is LOCKED - skipping.", 'Locked', 'OK', 'Warning') | Out-Null; continue }
        $type = if ($kv.Value -eq 'ESP') { '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } else { '{0fc63daf-8483-4772-8e79-3d69d8477de4}' }
        $todo += [pscustomobject]@{ Disk = $tp.Disk; Part = $tp.Number; Role = $kv.Value; Type = $type; Desc = ('Disk{0} Part{1}  {2} -> {3}' -f $tp.Disk, $tp.Number, $kv.Value, $(if ($kv.Value -eq 'ESP') { 'EFI System' } else { 'Linux fs' })) }
    }
    if ($todo.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No resolvable targets.', 'Nothing', 'OK', 'Information') | Out-Null; return }
    $msg = "Set the GPT type on these partitions? NO data is written - only each partition's type field changes (so the firmware/kernel recognise them):`r`n`r`n" + (($todo | ForEach-Object { '  ' + $_.Desc }) -join "`r`n")
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Set GPT types', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $errs = @()
    foreach ($t in $todo) {
        try { Set-Partition -DiskNumber $t.Disk -PartitionNumber $t.Part -GptType $t.Type -ErrorAction Stop }
        catch { $errs += ('{0}: {1}' -f $t.Role, $_.Exception.Message) }
    }
    Update-Tree; Update-Buttons
    if ($errs) { $status.Text = 'GPT type errors.'; [System.Windows.Forms.MessageBox]::Show(($errs -join "`r`n"), 'Errors', 'OK', 'Error') | Out-Null }
    else { $status.Text = 'GPT types set on targets - now bootable.'; [System.Windows.Forms.MessageBox]::Show('Done: ESP + Linux GPT types set on the targets.', 'Done', 'OK', 'Information') | Out-Null }
})

$btnProtect.Add_Click({
    $d = Get-SelectedDisk
    if (-not $d) { return }
    if (-not $d.Ids -or $d.Ids.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No stable disk id; cannot protect.', 'No id', 'OK', 'Warning') | Out-Null; return }
    if ($d.Protected) { [System.Windows.Forms.MessageBox]::Show('Already protected.', 'Protected', 'OK', 'Information') | Out-Null; return }
    $r = [System.Windows.Forms.MessageBox]::Show(('Mark Disk {0} ({1}) as PROTECTED (never whole-disk flash)?' -f $d.Number, $d.Name), 'Mark protected', 'YesNo', 'Question')
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { [void](Add-ProtectedIds $d.Ids ('Disk {0} {1}' -f $d.Number, $d.Name)); Update-Tree; $status.Text = 'Disk marked protected.' }
})

# =============================================================================
# Confirmation dialog (type FLASH)
# =============================================================================
function Confirm-Action([string]$Summary) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Confirm'; $dlg.Size = New-Object System.Drawing.Size(560, 360)
    $dlg.StartPosition = 'CenterParent'; $dlg.BackColor = [System.Drawing.Color]::FromArgb(30, 24, 24)
    $dlg.ForeColor = [System.Drawing.Color]::Gainsboro; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $msg = New-Object System.Windows.Forms.TextBox
    $msg.Multiline = $true; $msg.ReadOnly = $true; $msg.ScrollBars = 'Vertical'
    $msg.Location = New-Object System.Drawing.Point(14, 12); $msg.Size = New-Object System.Drawing.Size(520, 240)
    $msg.Font = New-Object System.Drawing.Font('Consolas', 9)
    $msg.BackColor = [System.Drawing.Color]::FromArgb(20, 16, 16); $msg.ForeColor = [System.Drawing.Color]::FromArgb(255, 190, 190)
    $msg.Text = $Summary; $dlg.Controls.Add($msg)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(14, 262); $box.Size = New-Object System.Drawing.Size(200, 24)
    $box.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 46); $box.ForeColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($box)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'FLASH'; $ok.Location = New-Object System.Drawing.Point(230, 262); $ok.Size = New-Object System.Drawing.Size(140, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(384, 262); $cancel.Size = New-Object System.Drawing.Size(140, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Controls.Add($cancel)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = $dlg.ShowDialog($form)
    return ($res -eq [System.Windows.Forms.DialogResult]::OK -and $box.Text.Trim() -ceq 'FLASH')
}

# =============================================================================
# Workers
# =============================================================================
$script:sync = $null; $script:ps = $null; $script:rs = $null; $script:handle = $null; $script:timer = $null

function Set-Busy([bool]$busy) {
    foreach ($c in @($btnFlash, $btnRefresh, $btnProtect, $btnLock, $btnUnlock, $btnTgtRoot, $btnTgtEsp, $btnTgtClear, $btnSetTypes, $cmbImg, $btnImgRefresh, $tree, $rbWhole, $rbPart)) { $c.Enabled = (-not $busy) }
}

$wholeScript = {
    param($DiskNumber, $ImagePath, $sync)
    try {
        $sync.Phase = 'Offlining disk...'
        try { Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction SilentlyContinue } catch {}
        $sync.Phase = 'Cleaning partition table...'
        $dp = "select disk $DiskNumber`r`nattributes disk clear readonly`r`nclean`r`noffline disk`r`nexit`r`n"
        $dp | diskpart.exe | Out-Null
        Start-Sleep -Seconds 2
        $sync.Phase = 'Flashing whole disk...'
        $disk = [System.IO.FileStream]::new("\\.\PhysicalDrive$DiskNumber", 'Open', 'Write', 'ReadWrite', 4MB, 'WriteThrough')
        $img  = [System.IO.FileStream]::new($ImagePath, 'Open', 'Read', 'Read', 4MB)
        try {
            $buf = New-Object byte[] (4MB)
            while (($r = $img.Read($buf, 0, $buf.Length)) -gt 0) { $disk.Write($buf, 0, $r); $sync.Written += $r }
            $disk.Flush()
        } finally { $img.Close(); $disk.Close() }
        $sync.Phase = 'Re-mounting + cleaning drive letters...'
        try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 2
        try {
            Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.DriveLetter) {
                    $v = $_ | Get-Volume -ErrorAction SilentlyContinue
                    if ($v -and $v.FileSystem -eq 'FAT32') {
                        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $_.PartitionNumber -AccessPath ("{0}:\" -f $_.DriveLetter) -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {}
        $sync.Phase = 'Done.'; $sync.Done = $true
    } catch { $sync.Error = $_.Exception.Message; $sync.Done = $true }
}

# Partition worker: write image partition payloads into target partition volumes.
# Every write goes through a per-partition volume handle (OS-bounded) AND is
# clamped in software to the source length AND to the OS-reported extent length.
$partScript = {
    param($Jobs, $sync)   # $Jobs = array of @{ Disk; PartNum; SelfGuid; ImgOffset; ImgSize; ImagePath; LockedGuids; Role }
    $BASICDATA = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    try {
        foreach ($j in $Jobs) {
            $sync.Phase = "Preparing $($j.Role) target..."
            # Hard refuse if this target's partition guid is on the locked list.
            if ($j.LockedGuids -contains $j.SelfGuid) { throw "Target is LOCKED ($($j.SelfGuid)) - aborting." }
            # Re-verify the partition by GUID (guard against disk re-enumeration).
            $p = Get-Partition -DiskNumber $j.Disk -PartitionNumber $j.PartNum -ErrorAction Stop
            $pg = $p.Guid.Trim('{', '}').ToLower()
            if ($pg -ne $j.SelfGuid) { throw "$($j.Role): partition GUID changed (re-enumerated) - aborting." }
            # Resolve a volume path. ext4/Linux partitions have none, so temporarily
            # set Basic Data type -> Windows exposes a volume we can write through.
            # (The write overwrites the partition anyway; final type is set below.)
            $vp = ($p.AccessPaths | Where-Object { $_ -match 'Volume\{' } | Select-Object -First 1)
            if (-not $vp) {
                $sync.Phase = "$($j.Role): temp Basic Data type to expose a volume..."
                Set-Partition -DiskNumber $j.Disk -PartitionNumber $j.PartNum -GptType $BASICDATA -ErrorAction Stop
                for ($i = 0; $i -lt 30 -and -not $vp; $i++) {
                    Start-Sleep -Milliseconds 500
                    $vp = ((Get-Partition -DiskNumber $j.Disk -PartitionNumber $j.PartNum -ErrorAction SilentlyContinue).AccessPaths | Where-Object { $_ -match 'Volume\{' } | Select-Object -First 1)
                }
                if (-not $vp) { throw "$($j.Role): no volume path even after Basic Data flip." }
            }
            $sync.Phase = "Opening $($j.Role) target volume..."
            $h = [VolumeIO]::OpenWriteLocked($vp)
            try {
                $extent = [VolumeIO]::GetLength($h)
                if ($j.ImgSize -gt $extent) { throw "$($j.Role): source $($j.ImgSize) > target extent $extent" }
                $vfs = New-Object System.IO.FileStream($h, [System.IO.FileAccess]::Write, 4MB)
                $img = [System.IO.FileStream]::new($j.ImagePath, 'Open', 'Read', 'Read', 4MB)
                try {
                    $img.Position = $j.ImgOffset
                    $remaining = [int64]$j.ImgSize
                    $wrote     = [int64]0
                    $buf = New-Object byte[] (4MB)
                    while ($remaining -gt 0) {
                        $want = [int]([Math]::Min([int64]$buf.Length, $remaining))
                        $read = $img.Read($buf, 0, $want)
                        if ($read -le 0) { break }
                        # Software clamp (the volume handle is already OS-bounded to the extent).
                        if (($wrote + $read) -gt $extent)     { throw "$($j.Role): write would exceed OS extent (clamp)" }
                        if (($wrote + $read) -gt $j.ImgSize)  { throw "$($j.Role): write would exceed source size (clamp)" }
                        $vfs.Write($buf, 0, $read)
                        $wrote     += $read
                        $remaining -= $read
                        $sync.Written += $read
                    }
                    $vfs.Flush()
                } finally { $img.Close(); $vfs.Close() }   # $vfs.Close() also closes $h
            } finally {
                # The FileStream already closed the underlying handle; closing it
                # releases the volume lock automatically. Guard so a stale handle
                # can't turn a successful write into a "failed" cleanup.
                try { if (-not $h.IsClosed) { [VolumeIO]::Unlock($h) } } catch {}
                try { if (-not $h.IsClosed) { $h.Close() } } catch {}
            }
            # Set the GPT type so the firmware/kernel recognises the target
            # (Windows created it as Basic Data). Only this partition's type field.
            $type = if ($j.Role -eq 'ESP') { '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } else { '{0fc63daf-8483-4772-8e79-3d69d8477de4}' }
            $sync.Phase = "$($j.Role): setting GPT type..."
            try { Set-Partition -DiskNumber $j.Disk -PartitionNumber $j.PartNum -GptType $type -ErrorAction Stop }
            catch { $sync.Warn += "Could not set $($j.Role) GPT type (Disk$($j.Disk) Part$($j.PartNum)): $($_.Exception.Message). " }
        }
        $sync.Phase = 'Done.'; $sync.Done = $true
    } catch { $sync.Error = $_.Exception.Message; $sync.Done = $true }
}

function Start-Worker([scriptblock]$Script, [object[]]$Arguments, [int64]$Total) {
    Set-Busy $true; $progress.Value = 0
    $script:sync = [hashtable]::Synchronized(@{ Written = 0; Total = $Total; Done = $false; Error = $null; Phase = 'Starting...'; Warn = '' })
    $script:rs = [runspacefactory]::CreateRunspace(); $script:rs.ApartmentState = 'MTA'; $script:rs.Open()
    $script:ps = [powershell]::Create(); $script:ps.Runspace = $script:rs
    $null = $script:ps.AddScript($Script)
    foreach ($a in $Arguments) { $null = $script:ps.AddArgument($a) }
    $null = $script:ps.AddArgument($script:sync)
    $script:handle = $script:ps.BeginInvoke()
    $script:timer = New-Object System.Windows.Forms.Timer; $script:timer.Interval = 300
    $script:timer.Add_Tick({
        $s = $script:sync
        if ($s.Total -gt 0 -and $s.Written -gt 0) {
            $pct = [math]::Min(100, [int](($s.Written / $s.Total) * 100)); $progress.Value = $pct
            $status.Text = '{0}  {1}%   ({2} / {3})' -f $s.Phase, $pct, (Format-Size $s.Written), (Format-Size $s.Total)
        } else { $status.Text = $s.Phase }
        if ($s.Done) {
            $script:timer.Stop()
            try { $script:ps.EndInvoke($script:handle) } catch {}
            try { $script:ps.Dispose(); $script:rs.Close() } catch {}
            Set-Busy $false; Update-Tree; Update-Buttons
            if ($s.Error) { $status.Text = 'FAILED: ' + $s.Error; [System.Windows.Forms.MessageBox]::Show($s.Error, 'Failed', 'OK', 'Error') | Out-Null }
            elseif ($s.Warn) { $progress.Value = 100; $status.Text = 'Done with warnings.'; [System.Windows.Forms.MessageBox]::Show('Data written, but: ' + $s.Warn, 'Done (warnings)', 'OK', 'Warning') | Out-Null }
            else { $progress.Value = 100; $status.Text = 'Complete.'; [System.Windows.Forms.MessageBox]::Show('Flash complete (targets written, GPT types set).', 'Done', 'OK', 'Information') | Out-Null }
        }
    })
    $script:timer.Start()
}

# =============================================================================
# FLASH button
# =============================================================================
$btnFlash.Add_Click({
    $img = Get-SelectedImagePath
    if (-not ($img -and (Test-Path $img))) { [System.Windows.Forms.MessageBox]::Show('No valid image.', 'No image', 'OK', 'Warning') | Out-Null; return }

    if (-not $rbPart.Checked) {
        # ---- WHOLE DISK ----
        $d = Get-SelectedDisk
        if (-not ($d -and $d.IsUsb -and -not $d.Protected)) { [System.Windows.Forms.MessageBox]::Show('Select a non-protected USB/SD disk.', 'Blocked', 'OK', 'Warning') | Out-Null; return }
        $imgSize = (Get-Item $img).Length
        if ($imgSize -gt $d.Size) { [System.Windows.Forms.MessageBox]::Show('Image larger than disk.', 'Too small', 'OK', 'Warning') | Out-Null; return }
        $sum = @"
WHOLE-DISK FLASH - ALL DATA ERASED

  Disk {0} - {1}
  Size   : {2}   Bus: {3}
  Write  : {4}  ({5})

Type FLASH to proceed.
"@ -f $d.Number, $d.Name, (Format-Size $d.Size), $d.BusType, (Split-Path $img -Leaf), (Format-Size $imgSize)
        if (-not (Confirm-Action $sum)) { return }
        Start-Worker $wholeScript @($d.Number, $img) $imgSize
        return
    }

    # ---- PARTITION ----
    $rootGuid = ($script:Roles.GetEnumerator() | Where-Object { $_.Value -eq 'ROOT' } | Select-Object -First 1).Key
    $espGuid  = ($script:Roles.GetEnumerator() | Where-Object { $_.Value -eq 'ESP' }  | Select-Object -First 1).Key
    if (-not $rootGuid) { [System.Windows.Forms.MessageBox]::Show('Set a ROOT (ext4) target first.', 'No root target', 'OK', 'Warning') | Out-Null; return }

    # resolve image partitions
    try { $imgParts = Get-ImagePartitions $img } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Image parse failed', 'OK', 'Error') | Out-Null; return }
    $imgEsp  = $imgParts | Where-Object { $_.Type -eq $ESP_TYPE }   | Select-Object -First 1
    $imgRoot = $imgParts | Where-Object { $_.Type -eq $LINUX_TYPE } | Select-Object -First 1
    if (-not $imgRoot) { [System.Windows.Forms.MessageBox]::Show('Image has no Linux/ext4 partition.', 'Bad image', 'OK', 'Error') | Out-Null; return }
    if ($espGuid -and -not $imgEsp) { [System.Windows.Forms.MessageBox]::Show('ESP target set but image has no ESP.', 'Bad image', 'OK', 'Error') | Out-Null; return }

    # re-resolve targets fresh from the inventory (by GUID) and re-check locks
    $locked = Get-LockedPartGuids
    $inv = Get-Inventory
    $allParts = $inv | ForEach-Object { $_.Partitions } | Where-Object { $_ }
    function FindPart($guid) { $allParts | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1 }

    $jobs = @(); $total = 0; $sumLines = @('PARTITION FLASH - only these targets are written:', '')
    foreach ($pair in @(@{G=$rootGuid;R='ROOT';I=$imgRoot}, @{G=$espGuid;R='ESP';I=$imgEsp})) {
        if (-not $pair.G) { continue }
        $tp = FindPart $pair.G
        if (-not $tp) { [System.Windows.Forms.MessageBox]::Show("$($pair.R) target partition vanished - refresh.", 'Gone', 'OK', 'Error') | Out-Null; return }
        if ($locked -contains $tp.Guid) { [System.Windows.Forms.MessageBox]::Show("$($pair.R) target is LOCKED - aborting.", 'Locked', 'OK', 'Error') | Out-Null; return }
        if ($pair.I.Size -gt $tp.Size) { [System.Windows.Forms.MessageBox]::Show(("$($pair.R): image part {0} > target {1}." -f (Format-Size $pair.I.Size), (Format-Size $tp.Size)), 'Too small', 'OK', 'Error') | Out-Null; return }
        $jobs += @{ ImgOffset = $pair.I.Offset; ImgSize = $pair.I.Size; ImagePath = $img; LockedGuids = $locked; SelfGuid = $tp.Guid; Role = $pair.R; Disk = $tp.Disk; PartNum = $tp.Number }
        $total += $pair.I.Size
        $sumLines += ('{0} -> Disk{1} Part{2}  ({3}, {4} {5} {6})' -f $pair.R, $tp.Disk, $tp.Number, (Format-Size $tp.Size), $tp.Fs, $tp.Label, $(if ($tp.Letter) { "($($tp.Letter):)" } else { '' }))
        $sumLines += ('     writing {0}{1}' -f (Format-Size $pair.I.Size), $(if ($tp.VolPath) { " into volume $($tp.VolPath)" } else { ' (ext4: temp Basic Data for write, then Linux)' }))
        $sumLines += ''
    }
    $sumLines += 'LOCKED/other partitions are NOT touched.'
    $sumLines += 'Each write is bounded by the OS to the target partition.'
    $sumLines += 'GPT type of each target is set (ESP / Linux) so it boots.'
    $sumLines += ''
    $sumLines += 'Type FLASH to proceed.'
    if (-not (Confirm-Action ($sumLines -join "`r`n"))) { return }
    Start-Worker $partScript @(,$jobs) $total
})

# =============================================================================
# Wiring
# =============================================================================
$btnRefresh.Add_Click({ Update-Tree; Update-Images; Update-Buttons })
$rbWhole.Add_CheckedChanged({ $tree.Invalidate(); Update-Buttons })
$rbPart.Add_CheckedChanged({ $tree.Invalidate(); Update-Buttons })
$cmbImg.Add_SelectedIndexChanged({ Update-Buttons })
$btnImgRefresh.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Disk images (*.img)|*.img|All files (*.*)|*.*'
    if (Test-Path $BuildDir) { $ofd.InitialDirectory = $BuildDir }
    if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $f = Get-Item $ofd.FileName
        $cmbImg.Items.Insert(0, ('{0}   ({1})   [{2}]' -f $f.Name, (Format-Size $f.Length), $f.FullName)); $cmbImg.SelectedIndex = 0
    }
})

Update-Images
Update-Tree
Update-Buttons
$status.Text = 'Ready. Mode (2): lock your data partitions (red+lock), set a ROOT target in free space, then FLASH.'
[System.Windows.Forms.Application]::EnableVisualStyles()
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
