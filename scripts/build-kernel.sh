#!/usr/bin/env bash
# =============================================================================
# Build Linux Kernel for Surface Pro 11 (Snapdragon X Plus / X1E80100)
#
# Uses the dwhinham SP11 kernel tree (x1e80100-microsoft-denali DTB + X1E80100
# patches that mainline lacks), configured from the Arch Linux ARM base config
# merged with our fragment — i.e. the proven SP11 build recipe.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

KERNEL_SRC="${SRC_DIR}/linux-sp11"
LOCALVERSION="-sp11"   # used only for the modules tarball filename

echo "========================================"
echo "  Kernel Build (SP11)"
echo "  Repo:   ${KERNEL_GIT_REPO}"
echo "  Branch: ${KERNEL_GIT_BRANCH}"
echo "========================================"

# Clone the SP11 kernel source (shallow, single branch)
if [[ ! -d "$KERNEL_SRC" ]]; then
    echo "[*] Cloning SP11 kernel..."
    git clone "$KERNEL_GIT_REPO" "$KERNEL_SRC" \
        --single-branch --branch "$KERNEL_GIT_BRANCH" --depth 1
fi

cd "$KERNEL_SRC"

# Configure: Arch Linux ARM linux-aarch64 base config merged with our fragment,
# then resolve the rest with olddefconfig. (merge_config.sh honours ARCH.)
echo "[*] Fetching Arch Linux ARM base kernel config..."
curl -Lo "${BUILD_DIR}/alarm_base_config" "$KERNEL_BASE_CONFIG_URL"

echo "[*] Merging base config + project fragment..."
ARCH="$ARCH" ./scripts/kconfig/merge_config.sh -O . -m \
    "${BUILD_DIR}/alarm_base_config" \
    "${CONFIGS_DIR}/kernel-config-fragment"
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# Optional project patches
if [[ -d "${PROJECT_ROOT}/patches/kernel" ]]; then
    for patch in "${PROJECT_ROOT}"/patches/kernel/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "[*] Applying patch: $(basename "$patch")"
        patch -p1 --forward < "$patch" || echo "    (already applied or failed)"
    done
fi

# Build kernel image, modules and dtbs (in-tree)
echo "[*] Building kernel (this takes a while)..."
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= -j"$(nproc)" Image modules dtbs

# Install modules into a staging dir
echo "[*] Installing modules to staging dir..."
MOD_STAGE="${KERNEL_BUILD_DIR}/modules_install"
rm -rf "$MOD_STAGE"; mkdir -p "$MOD_STAGE"
make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$MOD_STAGE" modules_install

# Collect outputs consumed by build-usb-image.sh
echo "[*] Collecting build artifacts..."
mkdir -p "${BUILD_DIR}/boot"
cp arch/arm64/boot/Image "${BUILD_DIR}/boot/Image"
rm -rf "${BUILD_DIR}/boot/dtbs"
cp -r arch/arm64/boot/dts/qcom "${BUILD_DIR}/boot/dtbs"

# Tarball of modules for the rootfs (name must match build-usb-image's KVER).
cd "$MOD_STAGE"
tar czf "${BUILD_DIR}/kernel-modules-${KERNEL_VERSION}${LOCALVERSION}.tar.gz" lib/

echo ""
echo "========================================"
echo "  Kernel Build Complete!"
echo "========================================"
echo "  Kernel:  ${BUILD_DIR}/boot/Image"
echo "  DTBs:    ${BUILD_DIR}/boot/dtbs/  (incl. x1e80100-microsoft-denali.dtb)"
echo "  Modules: ${BUILD_DIR}/kernel-modules-${KERNEL_VERSION}${LOCALVERSION}.tar.gz"
echo "========================================"
ls -1 "${BUILD_DIR}/boot/dtbs/" | grep -iE 'denali|romulus' || true
