#!/usr/bin/env bash
# =============================================================================
# Extract Qualcomm Firmware from Windows Driver Store
# Surface Pro 11 (Snapdragon X Plus 10-Core / X1E80100)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIVER_STORE="/c/Windows/System32/DriverStore/FileRepository"
FW_OUT="${PROJECT_ROOT}/firmware/qcom/x1e80100"

if [[ ! -d "$DRIVER_STORE" ]]; then
    echo "ERROR: Windows Driver Store not found at $DRIVER_STORE"
    echo "This script must be run from within Windows (MSYS2/WSL2 with Windows FS access)."
    exit 1
fi

echo "========================================"
echo "  Extracting Qualcomm X1E80100 Firmware"
echo "  Source: $DRIVER_STORE"
echo "  Output: $FW_OUT"
echo "========================================"

mkdir -p "$FW_OUT"/{adsp,cdsp,gpu,wlan,bt,video,camera,dsp,misc}

# --- GPU / Display (qcdx8380) ---
echo "[*] Extracting GPU/Display firmware..."
for dir in "$DRIVER_STORE"/qcdx8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.mbn "$FW_OUT/gpu/" 2>/dev/null || true
        cp -v "$dir"/*.bin "$FW_OUT/gpu/" 2>/dev/null || true
        cp -v "$dir"/qcdxkm8380.sys "$FW_OUT/misc/" 2>/dev/null || true
    fi
done

# --- Wi-Fi (qcwlanhmt8380) ---
echo "[*] Extracting Wi-Fi firmware..."
for dir in "$DRIVER_STORE"/qcwlanhmt8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/bdwlan* "$FW_OUT/wlan/" 2>/dev/null || true
        cp -v "$dir"/wlanfw* "$FW_OUT/wlan/" 2>/dev/null || true
        cp -v "$dir"/phy_ucode* "$FW_OUT/wlan/" 2>/dev/null || true
        cp -v "$dir"/Data* "$FW_OUT/wlan/" 2>/dev/null || true
    fi
done

# --- Bluetooth (qcbluetooth8380) ---
echo "[*] Extracting Bluetooth firmware..."
for dir in "$DRIVER_STORE"/qcbluetooth8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.bin "$FW_OUT/bt/" 2>/dev/null || true
    fi
done

# --- Audio DSP (surfacepro_ext_adsp8380 / qcadsprpc8380) ---
echo "[*] Extracting ADSP firmware..."
for dir in "$DRIVER_STORE"/surfacepro_ext_adsp8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.mbn "$FW_OUT/adsp/" 2>/dev/null || true
        cp -v "$dir"/*.jsn "$FW_OUT/adsp/" 2>/dev/null || true
        cp -v "$dir"/*.elf "$FW_OUT/adsp/" 2>/dev/null || true
        cp -v "$dir"/*.bin "$FW_OUT/adsp/" 2>/dev/null || true
        # ADSP shared libraries (optional, for reference)
        mkdir -p "$FW_OUT/adsp/libs"
        cp -v "$dir"/ADSP/*.so* "$FW_OUT/adsp/libs/" 2>/dev/null || true
        cp -v "$dir"/ADSP/fastrpc_shell_0 "$FW_OUT/adsp/libs/" 2>/dev/null || true
    fi
done

# --- Compute DSP (qcnspmcdm_ext_cdsp8380) ---
echo "[*] Extracting CDSP firmware..."
for dir in "$DRIVER_STORE"/qcnspmcdm_ext_cdsp8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.mbn "$FW_OUT/cdsp/" 2>/dev/null || true
    fi
done

# --- Video / EVA (qceva8380, qcdx8380 already captured some) ---
echo "[*] Extracting Video/EVA firmware..."
for dir in "$DRIVER_STORE"/qceva8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.mbn "$FW_OUT/video/" 2>/dev/null || true
    fi
done

# --- Camera (qccam*) ---
echo "[*] Extracting Camera ISP firmware..."
for dir in "$DRIVER_STORE"/qccamisp8380.inf_arm64_* "$DRIVER_STORE"/qccamisp_ext8380.inf_arm64_* \
         "$DRIVER_STORE"/qccamjpege8380.inf_arm64_* "$DRIVER_STORE"/qccammipicsi_ext8380.inf_arm64_* \
         "$DRIVER_STORE"/qccamsecureisp8380.inf_arm64_* "$DRIVER_STORE"/qccamsecureisp_ext8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.bin "$FW_OUT/camera/" 2>/dev/null || true
        cp -v "$dir"/*.mbn "$FW_OUT/camera/" 2>/dev/null || true
        cp -v "$dir"/*.elf "$FW_OUT/camera/" 2>/dev/null || true
    fi
done

# --- Sensors / Misc DSP ---
echo "[*] Extracting miscellaneous DSP configs..."
for dir in "$DRIVER_STORE"/qcadsprpc8380.inf_arm64_* "$DRIVER_STORE"/qcadsprpcd8380.inf_arm64_*; do
    if [[ -d "$dir" ]]; then
        cp -v "$dir"/*.mbn "$FW_OUT/dsp/" 2>/dev/null || true
        cp -v "$dir"/*.bin "$FW_OUT/dsp/" 2>/dev/null || true
    fi
done

# --- Generate firmware manifest ---
echo "[*] Generating firmware manifest..."
cat > "$FW_OUT/MANIFEST.txt" <<EOF
Qualcomm X1E80100 Firmware Extraction Manifest
===============================================
Device:    Microsoft Surface Pro 11
SoC:       Snapdragon X Plus (X1P-64-100) / X1E80100 platform
Source:    C:\\Windows\\System32\\DriverStore\\FileRepository
Extracted: $(date -Iseconds)

Directories:
  adsp/    - Audio DSP firmware (ADSP, remoteproc)
  cdsp/    - Compute DSP firmware (CDSP)
  gpu/     - GPU/Display microcode and firmware blobs
  wlan/    - Wi-Fi board data and firmware (WCN785x)
  bt/      - Bluetooth firmware
  video/   - Video encoder/decoder firmware (Venus/EVA)
  camera/  - Camera ISP firmware
  dsp/     - Generic DSP loader firmware
  misc/    - Other driver files

NOTE:
These firmware files were extracted from the Windows driver store.
Not all files may be directly loadable by the Linux kernel in their
current form. Some may require format conversion or specific driver
support. Use this as a reference and fallback during bringup.

Linux mainline typically expects firmware in /lib/firmware/qcom/x1e80100/
with specific naming conventions. Symlinks or copies may be needed.
EOF

echo ""
echo "========================================"
echo "  Extraction Complete!"
echo "========================================"
find "$FW_OUT" -type f | wc -l | xargs echo "Total files extracted:"
du -sh "$FW_OUT"
