#!/usr/bin/env bash
# =============================================================================
# Install Arch Linux ARM to Internal NVMe (Surface Pro 11)
# Supports dual-boot with Windows or clean install
# =============================================================================

set -euo pipefail

LOGFILE="/var/log/x1p-install.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOGFILE"
}

die() {
    log "FATAL: $*"
    exit 1
}

echo "========================================"
echo "  Surface Pro 11 NVMe Installer"
echo "========================================"
echo ""

# Detect NVMe device
NVME_DEVICE=$(lsblk -d -o NAME,MODEL | grep -i 'nvme\|microsoft\|samsung\|wd\|skhynix' | awk '{print "/dev/"$1}' | head -1)
if [[ -z "$NVME_DEVICE" ]]; then
    echo "Available block devices:"
    lsblk -d
    read -p "Enter target NVMe device (e.g., /dev/nvme0n1): " NVME_DEVICE
fi

if [[ ! -b "$NVME_DEVICE" ]]; then
    die "Invalid block device: ${NVME_DEVICE}"
fi

echo "Target device: ${NVME_DEVICE}"
echo ""

# Ask install mode
echo "Select installation mode:"
echo "  1) Dual-boot with existing Windows (resize/shrink required beforehand)"
echo "  2) Clean install — DESTROYS all data on ${NVME_DEVICE}"
echo "  3) Manual partitions (you've already created ESP, Boot, Root)"
read -p "Choice [1-3]: " INSTALL_MODE

# Verify
read -p "Type 'INSTALL' to confirm writing to ${NVME_DEVICE}: " CONFIRM
if [[ "$CONFIRM" != "INSTALL" ]]; then
    echo "Aborted."
    exit 1
fi

# Partitioning
case "$INSTALL_MODE" in
    2)
        log "Creating clean GPT partition table on ${NVME_DEVICE}..."
        parted -s "$NVME_DEVICE" mklabel gpt
        parted -s "$NVME_DEVICE" mkpart ESP fat32 1MiB 513MiB
        parted -s "$NVME_DEVICE" set 1 esp on
        parted -s "$NVME_DEVICE" mkpart Boot ext4 513MiB 1537MiB
        parted -s "$NVME_DEVICE" mkpart Root ext4 1537MiB 100%
        partprobe "$NVME_DEVICE"
        sleep 2
        ;;
    3)
        echo "Assuming partitions already exist."
        ;;
    *)
        echo "Dual-boot mode selected."
        echo "WARNING: Ensure you have freed up unallocated space first."
        echo "This script will create new partitions in the empty space."
        read -p "Continue? [y/N]: " DB_CONFIRM
        if [[ "$DB_CONFIRM" != "y" && "$DB_CONFIRM" != "Y" ]]; then
            exit 1
        fi
        # For dual-boot, we'd need to shrink Windows and create partitions in free space
        # This is complex and risky; provide guidance instead
        echo ""
        echo "For dual-boot, manually create partitions using parted/gdisk:"
        echo "  1. Shrink Windows partition from Windows Disk Management first"
        echo "  2. Create ESP (~512MB) if not already present"
        echo "  3. Create Boot (~1GB) and Root (~remaining) partitions"
        echo "  4. Run this installer again and select option 3) Manual partitions"
        exit 0
        ;;
esac

# Determine partition names
if [[ "$NVME_DEVICE" == *"nvme"* ]]; then
    ESP_PART="${NVME_DEVICE}p1"
    BOOT_PART="${NVME_DEVICE}p2"
    ROOT_PART="${NVME_DEVICE}p3"
else
    ESP_PART="${NVME_DEVICE}1"
    BOOT_PART="${NVME_DEVICE}2"
    ROOT_PART="${NVME_DEVICE}3"
fi

# Format
echo "[*] Formatting partitions..."
mkfs.fat -F 32 -n "ARCH_X1P_EFI" "$ESP_PART"
mkfs.ext4 -L "ARCH_X1P_BOOT" "$BOOT_PART"
mkfs.ext4 -L "ARCH_X1P_ROOT" "$ROOT_PART"

# Mount
MNT=/mnt/x1p-install
mkdir -p "$MNT"
mount "$ROOT_PART" "$MNT"
mkdir -p "${MNT}/boot"
mount "$BOOT_PART" "${MNT}/boot"
mkdir -p "${MNT}/boot/efi"
mount "$ESP_PART" "${MNT}/boot/efi"

# Copy rootfs
echo "[*] Copying rootfs to NVMe..."
# Use rsync if available, otherwise cp -a
if command -v rsync &>/dev/null; then
    rsync -aHAX --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/boot"} / "${MNT}/"
else
    cp -a --parents $(ls / | grep -v -E '^(dev|proc|sys|tmp|run|mnt|media|lost\+found|boot)$' | sed 's|^|/|') "$MNT/" 2>/dev/null || true
fi

# Re-mount bind /boot to copy kernel
echo "[*] Copying kernel and bootloader..."
cp -r /boot/. "${MNT}/boot/" 2>/dev/null || true

# Install systemd-boot to ESP
echo "[*] Installing systemd-boot..."
bootctl install --path="${MNT}/boot/efi" --no-variables

# Copy bootloader entries
mkdir -p "${MNT}/boot/efi/loader/entries"
cp /boot/efi/loader/loader.conf "${MNT}/boot/efi/loader/" 2>/dev/null || true
cp /boot/efi/loader/entries/*.conf "${MNT}/boot/efi/loader/entries/" 2>/dev/null || true

# Update fstab
echo "[*] Generating fstab..."
genfstab -U "$MNT" >> "${MNT}/etc/fstab" 2>/dev/null || cat >> "${MNT}/etc/fstab" <<EOF
# Surface Pro 11 NVMe partitions
UUID=$(blkid -s UUID -o value "$ESP_PART")  /boot/efi  vfat  defaults,noatime  0  2
UUID=$(blkid -s UUID -o value "$BOOT_PART")  /boot      ext4  defaults,noatime  0  2
UUID=$(blkid -s UUID -o value "$ROOT_PART")  /          ext4  defaults,noatime  0  1
EOF

# Rebuild initramfs for the installed system
echo "[*] Rebuilding initramfs..."
arch-chroot "$MNT" mkinitcpio -P 2>/dev/null || echo "    (mkinitcpio may need to be run manually)"

# Sync and unmount
sync
echo "[*] Unmounting..."
umount "${MNT}/boot/efi"
umount "${MNT}/boot"
umount "$MNT"

echo ""
echo "========================================"
echo "  Installation Complete!"
echo "========================================"
echo ""
echo "  Arch Linux ARM is installed to ${NVME_DEVICE}."
echo ""
echo "  To boot:"
echo "    1. Reboot the Surface Pro 11"
echo "    2. Hold Volume Down during boot for UEFI menu"
echo "    3. Select 'Arch Linux ARM' from boot options"
echo ""
echo "  For dual-boot with Windows, add a boot entry:"
echo "    bootctl set-default arch-x1p-gpu.conf"
echo ""
echo "  Logs: ${LOGFILE}"
echo "========================================"
