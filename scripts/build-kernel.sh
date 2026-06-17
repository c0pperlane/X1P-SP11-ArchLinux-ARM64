#!/usr/bin/env bash
# =============================================================================
# Build Linux Kernel for Surface Pro 11 (Snapdragon X Plus / X1E80100)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

KERNEL_SRC="${SRC_DIR}/linux-${KERNEL_VERSION}"
KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"

LOCALVERSION="-sp11"

echo "========================================"
echo "  Kernel Build"
echo "  Version: ${KERNEL_VERSION}${LOCALVERSION}"
echo "========================================"

# Download kernel source if not present
if [[ ! -d "$KERNEL_SRC" ]]; then
    echo "[*] Downloading kernel ${KERNEL_VERSION}..."
    mkdir -p "$SRC_DIR"
    if [[ -f "${CACHE_DIR}/${KERNEL_TARBALL}" ]]; then
        echo "[*] Using cached tarball"
        cp "${CACHE_DIR}/${KERNEL_TARBALL}" "${SRC_DIR}/"
    else
        curl -L -o "${SRC_DIR}/${KERNEL_TARBALL}" "$KERNEL_URL"
        cp "${SRC_DIR}/${KERNEL_TARBALL}" "${CACHE_DIR}/" 2>/dev/null || true
    fi
    echo "[*] Extracting..."
    tar -xf "${SRC_DIR}/${KERNEL_TARBALL}" -C "$SRC_DIR"
fi

cd "$KERNEL_SRC"

# Create output directory
mkdir -p "$KERNEL_BUILD_DIR"

# Configure kernel
# Start with defconfig, then merge our fragment
make O="$KERNEL_BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig

# Apply project config fragment
if [[ -f "${CONFIGS_DIR}/kernel-config-fragment" ]]; then
    echo "[*] Merging project config fragment..."
    # Use olddefconfig after appending fragment
    cat "${CONFIGS_DIR}/kernel-config-fragment" >> "${KERNEL_BUILD_DIR}/.config"
    make O="$KERNEL_BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
fi

# Optionally apply patches
if [[ -d "${PROJECT_ROOT}/patches/kernel" ]]; then
    for patch in "${PROJECT_ROOT}"/patches/kernel/*.patch; do
        if [[ -f "$patch" ]]; then
            echo "[*] Applying patch: $(basename "$patch")"
            patch -p1 --forward < "$patch" || echo "    (patch may already be applied or failed)"
        fi
    done
fi

# Build kernel image, modules, and dtbs
echo "[*] Building kernel..."
make O="$KERNEL_BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" Image modules dtbs

# Install modules
echo "[*] Installing modules to build dir..."
make O="$KERNEL_BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="${KERNEL_BUILD_DIR}/modules_install" modules_install

# Copy important outputs
echo "[*] Collecting build artifacts..."
mkdir -p "${BUILD_DIR}/boot"
cp "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" "${BUILD_DIR}/boot/Image"
cp -r "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/qcom" "${BUILD_DIR}/boot/dtbs" 2>/dev/null || true

# Create a tarball of modules for the rootfs
cd "${KERNEL_BUILD_DIR}/modules_install"
tar czf "${BUILD_DIR}/kernel-modules-${KERNEL_VERSION}${LOCALVERSION}.tar.gz" lib/

echo ""
echo "========================================"
echo "  Kernel Build Complete!"
echo "========================================"
echo "  Kernel:      ${BUILD_DIR}/boot/Image"
echo "  DTBs:        ${BUILD_DIR}/boot/dtbs/"
echo "  Modules:     ${BUILD_DIR}/kernel-modules-*.tar.gz"
echo "========================================"
