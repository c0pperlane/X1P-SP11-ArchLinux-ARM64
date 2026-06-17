<#
.SYNOPSIS
    Read a file or list a directory. Accepts Windows, WSL /mnt/<drv>/, and UNC paths.

.EXAMPLE
    readpath.bat "C:\path\to\file.txt"
    readpath.bat "E:\some\dir"
    readpath.bat "/mnt/c/Users/me/file.json"
    readpath.bat ".\build\arch-x1p-usb.img"
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

# ── Path normalization ─────────────────────────────────────────────────────────
# /mnt/<drive>/<rest>  ->  <Drive>:\<rest>     (WSL standard)
if ($Path -match '^/mnt/([a-zA-Z])/(.*)$') {
    $Path = $Matches[1].ToUpper() + ':\' + ($Matches[2] -replace '/', '\')
}
# /<drive>/<rest>      ->  <Drive>:\<rest>     (Git Bash / MSYS / Cygwin)
elseif ($Path -match '^/([a-zA-Z])/(.*)$') {
    $Path = $Matches[1].ToUpper() + ':\' + ($Matches[2] -replace '/', '\')
}

# ── Resolve to absolute ────────────────────────────────────────────────────────
$resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
if (-not $resolved) {
    Write-Error "Path not found: $Path"
    exit 1
}
$p = $resolved.Path

# ── Dispatch: file vs directory ────────────────────────────────────────────────
if (Test-Path -LiteralPath $p -PathType Leaf) {
    $info = Get-Item -LiteralPath $p
    if ($info.Length -gt 100MB) {
        Write-Warning "File is large ($([math]::Round($info.Length/1MB,1)) MB) -- reading anyway"
    }
    Get-Content -LiteralPath $p -Raw
}
elseif (Test-Path -LiteralPath $p -PathType Container) {
    Get-ChildItem -LiteralPath $p -Force |
        Select-Object Name,
                      @{N='Size';E={ if ($_.PSIsContainer) { '<dir>' } else { $_.Length } }},
                      Mode,
                      LastWriteTime |
        Format-Table -AutoSize |
        Out-String
}
else {
    Write-Error "Not a file or directory: $p"
    exit 1
}
