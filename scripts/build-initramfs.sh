#!/usr/bin/env bash
# =============================================================================
# Build Initramfs for Surface Pro 11 Kernel
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

KERNEL_SRC="${SRC_DIR}/linux-${KERNEL_VERSION}"
KERNEL_BUILD_DIR="${BUILD_DIR}/kernel"
INITRAMFS_OUT="${BUILD_DIR}/boot/initramfs.img"

echo "========================================"
echo "  Initramfs Build"
echo "========================================"

if [[ ! -d "${ROOTFS_BUILD_DIR}" ]]; then
    echo "ERROR: Rootfs not found. Run ./scripts/build-rootfs.sh first."
    exit 1
fi

# Method 1: Use dracut from the rootfs chroot (preferred)
if command -v arch-chroot &>/dev/null; then
    echo "[*] Building initramfs via chroot dracut/mkinitcpio..."
    
    # Copy kernel modules into rootfs if they exist
    if [[ -d "${KERNEL_BUILD_DIR}/modules_install/lib" ]]; then
        echo "[*] Syncing kernel modules into rootfs..."
        cp -a "${KERNEL_BUILD_DIR}/modules_install/lib/." "${ROOTFS_BUILD_DIR}/lib/"
    fi
    
    # Copy firmware
    if [[ -d "${PROJECT_ROOT}/firmware/qcom" ]]; then
        mkdir -p "${ROOTFS_BUILD_DIR}/lib/firmware/qcom"
        cp -a "${PROJECT_ROOT}/firmware/qcom/." "${ROOTFS_BUILD_DIR}/lib/firmware/qcom/"
    fi
    
    # Determine which tool to use
    if [[ -f "${ROOTFS_BUILD_DIR}/usr/bin/dracut" ]]; then
        echo "[*] Using dracut..."
        arch-chroot "$ROOTFS_BUILD_DIR" dracut --force --kver "${KERNEL_VERSION}${LOCALVERSION}" /boot/initramfs.img
        cp "${ROOTFS_BUILD_DIR}/boot/initramfs.img" "$INITRAMFS_OUT"
    elif [[ -f "${ROOTFS_BUILD_DIR}/usr/bin/mkinitcpio" ]]; then
        echo "[*] Using mkinitcpio..."
        # Copy our mkinitcpio config
        cp "${CONFIGS_DIR}/mkinitcpio.conf" "${ROOTFS_BUILD_DIR}/etc/mkinitcpio.conf"
        arch-chroot "$ROOTFS_BUILD_DIR" mkinitcpio -g /boot/initramfs.img -k "${KERNEL_VERSION}${LOCALVERSION}"
        cp "${ROOTFS_BUILD_DIR}/boot/initramfs.img" "$INITRAMFS_OUT"
    else
        echo "WARNING: Neither dracut nor mkinitcpio found in rootfs."
        echo "Creating a minimal fallback initramfs..."
        METHOD="fallback"
    fi
else
    echo "WARNING: arch-chroot not available. Creating minimal fallback initramfs..."
    METHOD="fallback"
fi

# Method 2: Minimal fallback initramfs
if [[ "${METHOD:-}" == "fallback" ]]; then
    echo "[*] Creating minimal fallback initramfs..."
    TMPDIR=$(mktemp -d)
    
    # Create minimal init structure
    mkdir -p "${TMPDIR}/"{bin,sbin,etc,proc,sys,dev,run,tmp,lib,lib64,usr}
    
    # Copy busybox or coreutils binaries from rootfs
    if [[ -f "${ROOTFS_BUILD_DIR}/bin/busybox" ]]; then
        cp "${ROOTFS_BUILD_DIR}/bin/busybox" "${TMPDIR}/bin/"
        for applet in sh mount umount switch_root sleep echo mkdir mknod; do
            ln -s busybox "${TMPDIR}/bin/${applet}" 2>/dev/null || true
        done
    else
        # Copy essential binaries
        for bin in bash mount umount switch_root sleep echo mkdir mknod modprobe insmod; do
            if [[ -f "${ROOTFS_BUILD_DIR}/usr/bin/${bin}" ]]; then
                cp "${ROOTFS_BUILD_DIR}/usr/bin/${bin}" "${TMPDIR}/bin/" 2>/dev/null || true
            elif [[ -f "${ROOTFS_BUILD_DIR}/bin/${bin}" ]]; then
                cp "${ROOTFS_BUILD_DIR}/bin/${bin}" "${TMPDIR}/bin/" 2>/dev/null || true
            fi
        done
        # Copy libraries needed by binaries
        for bin in "${TMPDIR}/bin/"*; do
            if [[ -f "$bin" ]]; then
                ldd "$bin" 2>/dev/null | grep -o '/lib[^ ]*' | while read lib; do
                    cp "${ROOTFS_BUILD_DIR}${lib}" "${TMPDIR}${lib}" 2>/dev/null || true
                done
            fi
        done
    fi
    
    # Copy kernel modules for essential drivers
    if [[ -d "${KERNEL_BUILD_DIR}/modules_install/lib/modules" ]]; then
        cp -a "${KERNEL_BUILD_DIR}/modules_install/lib/modules" "${TMPDIR}/lib/"
    fi
    
    # Create init script
    cat > "${TMPDIR}/init" <<'INIT_SCRIPT'
#!/bin/sh
set -e

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t tmpfs none /run

echo "Surface Pro 11 Fallback Initramfs"

# Load essential modules
modprobe nvme 2>/dev/null || true
modprobe usb_storage 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe msm 2>/dev/null || true

# Wait for root device
ROOT=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        root=*) ROOT="${arg#root=}" ;;
    esac
done

if [[ -z "$ROOT" ]]; then
    echo "ERROR: No root= parameter found"
    /bin/sh
fi

# Resolve LABEL or UUID
if [[ "$ROOT" == LABEL=* ]]; then
    LABEL="${ROOT#LABEL=}"
    ROOT="/dev/disk/by-label/${LABEL}"
elif [[ "$ROOT" == UUID=* ]]; then
    UUID="${ROOT#UUID=}"
    ROOT="/dev/disk/by-uuid/${UUID}"
fi

# Wait for device
for i in $(seq 1 30); do
    if [[ -e "$ROOT" ]]; then
        break
    fi
    echo "Waiting for root device ${ROOT}... (${i}/30)"
    sleep 1
done

if [[ ! -e "$ROOT" ]]; then
    echo "ERROR: Root device not found"
    /bin/sh
fi

# Mount root
mkdir -p /mnt/root
mount "$ROOT" /mnt/root

# Switch root
exec switch_root /mnt/root /sbin/init
INIT_SCRIPT
    chmod +x "${TMPDIR}/init"
    
    # Create cpio archive
    cd "$TMPDIR"
    find . | cpio -o -H newc | gzip > "$INITRAMFS_OUT"
    cd - >/dev/null
    rm -rf "$TMPDIR"
fi

echo ""
echo "========================================"
echo "  Initramfs Build Complete!"
echo "  Output: ${INITRAMFS_OUT}"
echo "========================================"
