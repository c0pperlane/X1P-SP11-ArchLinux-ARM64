#!/bin/bash
set -e

# =============================================================================
# Arch Linux ARM64 Rootfs Builder for Surface Pro 11 (X1E80100)
# =============================================================================
# Downloads official Arch Linux ARM aarch64 rootfs, extracts it, applies
# custom skel overlays, installs kernel modules, and prepares a bootable
# root filesystem.
#
# The resulting rootfs/ directory can be:
#   - Edited directly (add packages, config files, etc.)
#   - Copied into the USB image by build-usb-image.sh
#   - rsync'd to a real installation
# =============================================================================

source "$(dirname "$0")/env.sh"

ROOTFS_DIR="${ROOTFS_DIR:-$PROJECT_ROOT/rootfs}"
ROOTFS_WSL="/root/x1p-build/rootfs"
ARCH_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
CACHE_DIR="$PROJECT_ROOT/cache"
TARBALL="$CACHE_DIR/archlinuxarm-aarch64-latest.tar.gz"

echo "========================================"
echo "  Arch Linux ARM64 Rootfs Builder"
echo "  Target: Surface Pro 11 (X1E80100)"
echo "========================================"

# =============================================================================
# Step 1: Download rootfs tarball (if not cached)
# =============================================================================
mkdir -p "$CACHE_DIR"

if [ -f "$TARBALL" ]; then
    echo "[*] Using cached tarball: $TARBALL"
else
    echo "[*] Downloading Arch Linux ARM aarch64 rootfs..."
    echo "    URL: $ARCH_URL"
    curl -L --progress-bar -o "$TARBALL" "$ARCH_URL"
    echo "[*] Download complete."
fi

# =============================================================================
# Step 2: Extract into rootfs directory (WSL2 native ext4 for performance)
# =============================================================================
echo "[*] Preparing rootfs directory..."
rm -rf "$ROOTFS_WSL"
mkdir -p "$ROOTFS_WSL"

echo "[*] Extracting tarball to $ROOTFS_WSL ..."
tar xzf "$TARBALL" -C "$ROOTFS_WSL" --warning=no-unknown-keyword

# =============================================================================
# Step 3: Apply skel overlays
# =============================================================================
echo "[*] Applying skel overlays..."
if [ -d "$PROJECT_ROOT/skel" ]; then
    cp -a "$PROJECT_ROOT/skel/"* "$ROOTFS_WSL/"
fi

# =============================================================================
# Step 4: Install kernel modules into rootfs
# =============================================================================
echo "[*] Installing kernel modules into rootfs..."
MOD_SRC="$PROJECT_ROOT/kernel/modules/modules"
if [ -d "$MOD_SRC" ]; then
    mkdir -p "$ROOTFS_WSL/lib/modules"
    rsync -a --delete "$MOD_SRC/" "$ROOTFS_WSL/lib/modules/"
    MODULE_COUNT=$(find "$ROOTFS_WSL/lib/modules" -name "*.ko" | wc -l)
    echo "    Installed $MODULE_COUNT modules"
else
    echo "    [!] Warning: No kernel modules found at $MOD_SRC"
fi

# =============================================================================
# Step 5: Configure system basics
# =============================================================================
echo "[*] Configuring system..."

# Hostname
echo "surface-pro11-x1p" > "$ROOTFS_WSL/etc/hostname"

# Locale
cat > "$ROOTFS_WSL/etc/locale.gen" <<'EOF'
en_US.UTF-8 UTF-8
EOF

# Locale.conf
cat > "$ROOTFS_WSL/etc/locale.conf" <<'EOF'
LANG=en_US.UTF-8
EOF

# VConsole (font/keymap)
cat > "$ROOTFS_WSL/etc/vconsole.conf" <<'EOF'
KEYMAP=us
FONT=ter-v16n
EOF

# fstab for USB boot
cat > "$ROOTFS_WSL/etc/fstab" <<'EOF'
# Static information about the filesystems.
# <file system>        <dir>    <type>    <options>                    <dump> <pass>
LABEL=X1P_BOOT         /boot    vfat      defaults,noatime             0      2
LABEL=ARCH_X1P_ROOT    /        ext4      defaults,noatime             0      1
EOF

# Timezone (UTC by default, user can change)
ln -sf /usr/share/zoneinfo/UTC "$ROOTFS_WSL/etc/localtime" 2>/dev/null || true

# Enable DHCP on all interfaces
cat > "$ROOTFS_WSL/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
EOF

cat > "$ROOTFS_WSL/etc/systemd/network/25-wireless.network" <<'EOF'
[Match]
Name=wl*
Name=wlan*

[Network]
DHCP=yes
EOF

# Enable systemd-networkd and systemd-resolved
chroot "$ROOTFS_WSL" systemctl enable systemd-networkd 2>/dev/null || true
chroot "$ROOTFS_WSL" systemctl enable systemd-resolved 2>/dev/null || true

# Enable sshd
chroot "$ROOTFS_WSL" systemctl enable sshd 2>/dev/null || true

# Enable render-mode setup service (configures GPU/SW env before display manager)
chroot "$ROOTFS_WSL" systemctl enable x1p-render-setup 2>/dev/null || true

# =============================================================================
# Step 5b: Install Qcom GPU firmware required by the MSM/Freedreno driver
# =============================================================================
# The MSM DRM driver (CONFIG_DRM_MSM=y) requires two firmware files to
# initialise the Adreno X1-85 GPU on X1E80100:
#
#   /lib/firmware/qcom/x1e80100/a690_sqe.fw   — CP SQE microcode (command processor)
#   /lib/firmware/qcom/x1e80100/a690_gmu.bin  — GMU firmware (power management unit)
#
# These come from the linux-firmware package (upstream). The Windows-extracted
# blobs in firmware/qcom/x1e80100/gpu/ are DXKM/proprietary display driver blobs
# and are NOT used by the open-source MSM driver.
#
# Strategy: install linux-firmware inside the rootfs via pacman, then also copy
# the extracted Windows blobs alongside for completeness (they may be needed by
# future drivers or as reference).
#
echo "[*] Installing linux-firmware (required for Adreno X1-85 GPU)..."
if chroot "$ROOTFS_WSL" pacman -Sy --noconfirm linux-firmware 2>/dev/null; then
    echo "    linux-firmware installed via pacman"
else
    echo "    [!] pacman unavailable (expected in build env); skipping package install."
    echo "    Ensure linux-firmware is installed on the target system before first boot."
    echo "    Required: /lib/firmware/qcom/x1e80100/a690_sqe.fw"
    echo "              /lib/firmware/qcom/x1e80100/a690_gmu.bin"
fi

# Copy Windows-extracted GPU blobs into the rootfs at the correct path.
# These are supplemental; the MSM driver will ignore files it does not recognise.
QCOM_FW_DST="$ROOTFS_WSL/lib/firmware/qcom/x1e80100"
GPU_FW_SRC="$PROJECT_ROOT/firmware/qcom/x1e80100/gpu"
if [ -d "$GPU_FW_SRC" ]; then
    echo "[*] Copying extracted Qualcomm GPU firmware blobs to rootfs..."
    mkdir -p "$QCOM_FW_DST"
    cp -a "$GPU_FW_SRC/"* "$QCOM_FW_DST/"
    echo "    Copied $(ls "$GPU_FW_SRC" | wc -l) firmware files"
fi

# =============================================================================
# Step 6: Create convenience symlinks / shortcuts
# =============================================================================
echo "[*] Creating project shortcuts..."
rm -f "$ROOTFS_DIR"
ln -sf "$ROOTFS_WSL" "$ROOTFS_DIR" 2>/dev/null || \
    echo "    (Note: Windows symlink failed; rootfs is at $ROOTFS_WSL)"

# =============================================================================
# Step 7: Print summary
# =============================================================================
ROOTFS_SIZE=$(du -sh "$ROOTFS_WSL" | cut -f1)

echo ""
echo "========================================"
echo "  Rootfs Built Successfully!"
echo "========================================"
echo "  Location (WSL2): $ROOTFS_WSL"
echo "  Size:             $ROOTFS_SIZE"
echo ""
echo "  From Windows, access via:"
echo "    Explorer:  \\\\wsl$\\Ubuntu\\root\\x1p-build\\rootfs\\"
echo "    VS Code:   code \\\\wsl$\\Ubuntu\\root\\x1p-build\\rootfs\\"
echo ""
echo "  To edit:"
echo "    wsl -d Ubuntu -u root"
echo "    cd /root/x1p-build/rootfs"
echo ""
echo "  To assemble USB image:"
echo "    bash scripts/build-usb-image.sh"
echo "========================================"
