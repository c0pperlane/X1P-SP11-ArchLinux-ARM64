#!/usr/bin/env bash
# =============================================================================
# Flash USB Image to Physical Device
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

DEVICE="${1:-}"
IMAGE_FILE="${IMAGE_OUTPUT}"

if [[ -z "$DEVICE" ]]; then
    echo "Usage: $0 <device>"
    echo ""
    echo "Example:"
    echo "  $0 /dev/sdX"
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E 'usb|sd|mmc' || lsblk -d
    exit 1
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "ERROR: Image file not found: ${IMAGE_FILE}"
    echo "Run ./scripts/build-usb-image.sh first."
    exit 1
fi

# Safety checks
if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk0"* ]]; then
    echo "ERROR: ${DEVICE} looks like an internal storage device!"
    echo "This script is for USB/external devices only."
    echo "If you really want to flash internal storage, use dd manually."
    exit 1
fi

if mount | grep -q "^${DEVICE}"; then
    echo "ERROR: ${DEVICE} appears to be mounted. Please unmount it first."
    exit 1
fi

echo "========================================"
echo "  FLASH USB DEVICE"
echo "========================================"
echo "  Image:  ${IMAGE_FILE}"
echo "  Device: ${DEVICE}"
echo "  Size:   $(ls -lh "$IMAGE_FILE" | awk '{print $5}')"
echo ""
echo "  WARNING: This will DESTROY all data on ${DEVICE}!"
echo "========================================"
read -p "Are you sure? Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo "[*] Flashing..."
sudo dd if="$IMAGE_FILE" of="$DEVICE" bs=4M status=progress conv=fsync

echo "[*] Syncing..."
sync

echo ""
echo "========================================"
echo "  Flash Complete!"
echo "========================================"
echo "  Device ${DEVICE} is ready."
echo ""
echo "  To boot on Surface Pro 11:"
echo "    1. Insert the USB drive"
echo "    2. Hold Volume Down + press Power"
echo "    3. Select USB device from UEFI boot menu"
echo "    4. Choose 'GPU Accelerated' or 'Software Rendering'"
echo "========================================"
