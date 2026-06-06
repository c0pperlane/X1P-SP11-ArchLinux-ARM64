#!/usr/bin/env bash
# =============================================================================
# Master Build Script — Surface Pro 11 Arch Linux ARM
# =============================================================================
# Usage: ./scripts/build-all.sh [image_size]
#   image_size: e.g., 8G, 16G (default: 8G)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

IMAGE_SIZE="${1:-8G}"

echo "========================================"
echo "  Surface Pro 11 — Full Build Pipeline"
echo "========================================"
echo ""

# Step 1: Extract firmware
echo "[STEP 1/5] Extracting Qualcomm firmware from Windows Driver Store..."
if [[ -d /c/Windows/System32/DriverStore/FileRepository ]]; then
    bash scripts/extract-firmware.sh
else
    echo "  Skipping (not on Windows). Ensure firmware is in firmware/qcom/"
fi

# Step 2: Build kernel
echo ""
echo "[STEP 2/5] Building Linux kernel..."
bash scripts/build-kernel.sh

# Step 3: Build rootfs
echo ""
echo "[STEP 3/5] Building root filesystem..."
bash scripts/build-rootfs.sh

# Step 4: Build USB image
echo ""
echo "[STEP 4/5] Building USB disk image (${IMAGE_SIZE})..."
bash scripts/build-usb-image.sh "$IMAGE_SIZE"

# Step 5: Summary
echo ""
echo "[STEP 5/5] Build summary..."
echo ""
ls -lh build/*.img build/*.tar.gz 2>/dev/null || true

echo ""
echo "========================================"
echo "  BUILD COMPLETE!"
echo "========================================"
echo ""
echo "  Next steps:"
echo "    1. Flash to USB:   sudo ./scripts/flash-usb.sh /dev/sdX"
echo "    2. Boot on Surface Pro 11 via Volume Down + Power"
echo "    3. Select GPU mode from systemd-boot menu"
echo "    4. Install to NVMe: sudo install-to-nvme"
echo ""
echo "  Project files are in: $(pwd)"
echo "========================================"
