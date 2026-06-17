#!/usr/bin/env bash
# =============================================================================
# Arch Linux ARM64 for Surface Pro 11 (Snapdragon X Plus)
# Common Environment Configuration
# =============================================================================

set -euo pipefail

# Determine project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export BUILD_DIR="${PROJECT_ROOT}/build"
export CACHE_DIR="${PROJECT_ROOT}/cache"
export SRC_DIR="${PROJECT_ROOT}/src"
export CONFIGS_DIR="${PROJECT_ROOT}/configs"
export SKEL_DIR="${PROJECT_ROOT}/skel"

# Build directories
export KERNEL_BUILD_DIR="${BUILD_DIR}/kernel"
export ROOTFS_BUILD_DIR="${BUILD_DIR}/rootfs"
export IMAGE_OUTPUT="${BUILD_DIR}/arch-surface-pro11-x1p-live.img"

# Native WSL build directory — on ext4, NOT on the 9P Windows bridge (/mnt/c).
# All intermediate artifacts (image assembly, rootfs staging) live here.
# Only the final .img is copied to the Windows project dir at the end.
export NATIVE_BUILD_DIR="/root/x1p-build"

# Versions
# The Surface Pro 11 needs the dwhinham SP11 kernel: it carries the
# x1e80100-microsoft-denali DTB and X1E80100 patches that mainline lacks.
export KERNEL_VERSION="6.17"
export KERNEL_GIT_REPO="https://github.com/dwhinham/kernel-surface-pro-11"
export KERNEL_GIT_BRANCH="wip/x1e80100-6.17-sp11"
export KERNEL_BASE_CONFIG_URL="https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/linux-aarch64/config"
export ALARM_ARCH="aarch64"
export ALARM_MIRROR="http://os.archlinuxarm.org/os"
export ALARM_TARBALL="ArchLinuxARM-aarch64-latest.tar.gz"

# Target platform
export TARGET_SOC="x1e80100"
export TARGET_DTB_PREFIX="x1e80100"
export TARGET_DEVICE="microsoft-surface-pro11"
export TARGET_GPU="adreno-x1-85"

# Toolchain detection
if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export ARCH="arm64"
elif command -v aarch64-linux-gcc &>/dev/null; then
    export CROSS_COMPILE="aarch64-linux-"
    export ARCH="arm64"
else
    # Native ARM64 build
    MACHINE=$(uname -m)
    if [[ "$MACHINE" == "aarch64" || "$MACHINE" == "arm64" ]]; then
        export ARCH="arm64"
        export CROSS_COMPILE=""
    else
        echo "WARNING: No ARM64 cross-compiler found!"
        echo "Install aarch64-linux-gnu-gcc or run on an ARM64 machine."
        echo ""
        echo "Debian/Ubuntu: sudo apt install gcc-aarch64-linux-gnu"
        echo "Arch:          sudo pacman -S aarch64-linux-gnu-gcc"
        echo ""
        read -p "Press Enter to continue anyway or Ctrl+C to abort..."
        export ARCH="arm64"
        export CROSS_COMPILE=""
    fi
fi

# Create directories
mkdir -p "${BUILD_DIR}" "${CACHE_DIR}" "${SRC_DIR}" "${NATIVE_BUILD_DIR}"

echo "========================================"
echo "  Arch Surface Pro 11 X1P Build Env"
echo "========================================"
echo "PROJECT_ROOT:     ${PROJECT_ROOT}"
echo "BUILD_DIR:        ${BUILD_DIR}"
echo "NATIVE_BUILD_DIR: ${NATIVE_BUILD_DIR}"
echo "ARCH:             ${ARCH}"
echo "CROSS_COMPILE:    ${CROSS_COMPILE}"
echo "KERNEL:           ${KERNEL_GIT_BRANCH}"
echo "SOC:              ${TARGET_SOC}"
echo "GPU:              ${TARGET_GPU}"
echo "========================================"
