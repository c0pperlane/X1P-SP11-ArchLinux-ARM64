#!/bin/bash
# =============================================================================
# Fast USB Image Patcher — Surface Pro 11 (X1E80100)
# =============================================================================
# Updates kernel, initramfs, dtbs, and boot entries inside an existing image
# WITHOUT rebuilding rootfs or recreating the image from scratch.
#
# Typical time: ~2 minutes (vs 30+ min for a full build).
#
# Usage:
#   sudo bash scripts/patch-usb-image.sh [path/to/arch-x1p-usb.img]
#
# If no image path is given, defaults to build/arch-x1p-usb.img
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
WIN_IMAGE_FILE="${1:-${BUILD_DIR}/arch-x1p-usb.img}"
WORK_DIR="${NATIVE_BUILD_DIR}/patch-work"
WORK_IMAGE="${WORK_DIR}/arch-x1p-usb.img"

LABEL_EFI="X1P_BOOT"
LABEL_ROOT="ARCH_X1P_ROOT"

BOOT_SRC="$PROJECT_ROOT/boot"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
echo "========================================"
echo "  Fast USB Image Patcher"
echo "  Target: Surface Pro 11 (X1E80100)"
echo "========================================"
echo ""

MISSING=0
for cmd in losetup partprobe mcopy mmd mdir mformat e2label; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[!] Missing required tool: $cmd  (install mtools / e2fsprogs)"
        MISSING=1
    fi
done
[[ "$MISSING" -eq 1 ]] && exit 1

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -f "$WIN_IMAGE_FILE" ]]; then
    echo "[!] Source image not found: $WIN_IMAGE_FILE"
    echo "    Run a full build first:"
    echo "      bash scripts/build-usb-image.sh"
    exit 1
fi

if [[ ! -d "$BOOT_SRC" ]]; then
    echo "[!] Boot source directory not found: $BOOT_SRC"
    echo "    Run the kernel build first:"
    echo "      bash scripts/build-kernel.sh"
    exit 1
fi

# Warn if neither kernel nor initramfs changed
PATCHED_SOMETHING=0
for f in Image initramfs.img; do
    [[ -f "$BOOT_SRC/$f" ]] && PATCHED_SOMETHING=1
done
if [[ "$PATCHED_SOMETHING" -eq 0 ]]; then
    echo "[!] Nothing to patch: no Image or initramfs.img found in $BOOT_SRC"
    exit 1
fi

echo "  Source image : $WIN_IMAGE_FILE"
echo "  Work dir     : $WORK_DIR"
echo "  Boot source  : $BOOT_SRC"
echo ""

# ---------------------------------------------------------------------------
# Set up work area on native WSL ext4
# ---------------------------------------------------------------------------
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "[*] Copying image to native WSL filesystem (avoids slow 9P writes)..."
cp --sparse=always -v "$WIN_IMAGE_FILE" "$WORK_IMAGE"

# ---------------------------------------------------------------------------
# Attach loop device
# ---------------------------------------------------------------------------
echo "[*] Attaching loop device..."
LOOP_DEV=$(losetup -f --show -P "$WORK_IMAGE")
EFI_DEV="${LOOP_DEV}p1"
ROOT_DEV="${LOOP_DEV}p2"

sleep 1
partprobe "$LOOP_DEV" 2>/dev/null || true

cleanup() {
    echo "[*] Cleaning up loop device..."
    losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

# Verify the FAT partition is accessible
if ! mdir -i "$EFI_DEV" :: &>/dev/null; then
    echo "[!] Cannot read EFI partition via mtools. Is the image healthy?"
    echo "    EFI device: $EFI_DEV"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: copy a directory tree into a FAT image via mtools
# Parent directories are always created before children (sorted find).
# ---------------------------------------------------------------------------
mtools_copy_tree() {
    local SRC="$1"
    local IMG="$2"
    local DST="$3"   # e.g. "/" or "/dtbs/"

    find "$SRC" -mindepth 1 -type d | sort | while read -r dir; do
        local rel="${dir#$SRC/}"
        mmd -i "$IMG" "::${DST}${rel}" 2>/dev/null || true
    done

    find "$SRC" -mindepth 1 -type f | while read -r file; do
        local rel="${file#$SRC/}"
        [[ "$(dirname "$rel")" != "." ]] && mmd -i "$IMG" "::${DST}$(dirname "$rel")" 2>/dev/null || true
        mcopy -i "$IMG" -o "$file" "::${DST}${rel}"
    done
}

# ---------------------------------------------------------------------------
# Patch: kernel Image
# ---------------------------------------------------------------------------
if [[ -f "$BOOT_SRC/Image" ]]; then
    echo "[*] Patching kernel Image..."
    mcopy -i "$EFI_DEV" -o "$BOOT_SRC/Image" "::Image"
    echo "    $(du -h "$BOOT_SRC/Image" | cut -f1) written"
else
    echo "[-] No Image found in $BOOT_SRC — skipping kernel patch"
fi

# ---------------------------------------------------------------------------
# Patch: initramfs
# ---------------------------------------------------------------------------
if [[ -f "$BOOT_SRC/initramfs.img" ]]; then
    echo "[*] Patching initramfs.img..."
    mcopy -i "$EFI_DEV" -o "$BOOT_SRC/initramfs.img" "::initramfs.img"
    echo "    $(du -h "$BOOT_SRC/initramfs.img" | cut -f1) written"
else
    echo "[-] No initramfs.img found in $BOOT_SRC — skipping"
fi

# ---------------------------------------------------------------------------
# Patch: systemd-boot loader entries
# ---------------------------------------------------------------------------
if [[ -d "$BOOT_SRC/loader/entries" ]]; then
    echo "[*] Patching loader/entries/..."
    mmd -i "$EFI_DEV" "::loader" 2>/dev/null || true
    mmd -i "$EFI_DEV" "::loader/entries" 2>/dev/null || true
    find "$BOOT_SRC/loader/entries" -type f | while read -r f; do
        mcopy -i "$EFI_DEV" -o "$f" "::loader/entries/$(basename "$f")"
        echo "    $(basename "$f")"
    done
fi

if [[ -f "$BOOT_SRC/loader/loader.conf" ]]; then
    echo "[*] Patching loader/loader.conf..."
    mmd -i "$EFI_DEV" "::loader" 2>/dev/null || true
    mcopy -i "$EFI_DEV" -o "$BOOT_SRC/loader/loader.conf" "::loader/loader.conf"
fi

# ---------------------------------------------------------------------------
# Patch: dtbs
# ---------------------------------------------------------------------------
if [[ -d "$BOOT_SRC/dtbs" ]]; then
    echo "[*] Patching dtbs/ tree..."
    mtools_copy_tree "$BOOT_SRC/dtbs" "$EFI_DEV" "/dtbs/"
    DTB_COUNT=$(find "$BOOT_SRC/dtbs" -type f | wc -l)
    echo "    ${DTB_COUNT} dtb file(s) updated"
else
    echo "[-] No dtbs/ directory found — skipping"
fi

# ---------------------------------------------------------------------------
# Verify / fix root partition label
# ---------------------------------------------------------------------------
echo "[*] Verifying root partition label (ext4)..."
CURRENT_LABEL=$(e2label "$ROOT_DEV" 2>/dev/null || echo "")
if [[ "$CURRENT_LABEL" != "$LABEL_ROOT" ]]; then
    echo "    Fixing label: '${CURRENT_LABEL:-<empty>}' -> '$LABEL_ROOT'"
    e2label "$ROOT_DEV" "$LABEL_ROOT"
else
    echo "    Label OK: $LABEL_ROOT"
fi

# ---------------------------------------------------------------------------
# Detach loop device
# ---------------------------------------------------------------------------
losetup -d "$LOOP_DEV"
trap - EXIT

# ---------------------------------------------------------------------------
# Copy patched image back to Windows build directory
# ---------------------------------------------------------------------------
echo "[*] Copying patched image back to Windows build/..."
mkdir -p "$BUILD_DIR"
cp --sparse=always -v "$WORK_IMAGE" "$WIN_IMAGE_FILE"
rm -rf "$WORK_DIR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Patch Complete!"
echo "========================================"
echo "  Image : $WIN_IMAGE_FILE"
echo "  Size  : $(du -h "$WIN_IMAGE_FILE" | cut -f1)"
echo ""
echo "  Boot entries present:"
# List entries from the patched image without re-mounting
mdir -i "${WIN_IMAGE_FILE}@@$((512 * 2048))" "::loader/entries/" 2>/dev/null \
    | grep -i "\.conf" | awk '{print "    -", $NF}' || \
    ls -1 "$BOOT_SRC/loader/entries/" 2>/dev/null | sed 's/^/    - /' || true
echo ""
echo "  Next: flash with scripts/_autoflash.ps1 (Run as Admin)"
echo "========================================"
