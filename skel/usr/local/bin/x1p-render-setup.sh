#!/usr/bin/env bash
# =============================================================================
# Surface Pro 11 Render Mode Setup
# Configures GPU acceleration or software rendering based on kernel cmdline
# =============================================================================

LOGFILE="/var/log/x1p-render.log"
mkdir -p "$(dirname "$LOGFILE")"

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOGFILE"
}

# Read kernel command line
CMDLINE=$(cat /proc/cmdline)

# Determine render mode
RENDER_MODE="auto"
if [[ "$CMDLINE" == *"x1p.render=hw"* ]]; then
    RENDER_MODE="hw"
elif [[ "$CMDLINE" == *"x1p.render=sw"* ]]; then
    RENDER_MODE="sw"
elif [[ "$CMDLINE" == *"x1p.render=safe"* ]]; then
    RENDER_MODE="safe"
fi

log "=============================================="
log "Surface Pro 11 Render Mode Setup"
log "Detected mode: ${RENDER_MODE}"
log "=============================================="

# Create runtime environment directory
mkdir -p /run/x1p

# Write mode marker
echo "$RENDER_MODE" > /run/x1p/render_mode

# Apply configuration based on mode
case "$RENDER_MODE" in
    hw)
        log "Configuring for GPU Hardware Acceleration..."
        # Ensure MSM module is loaded (if not blacklisted)
        modprobe msm 2>/dev/null || log "WARNING: msm module failed to load"

        # Verify that the MSM DRM node actually initialised before committing to hw mode.
        # The GPU render node appears at /dev/dri/renderD128 once the MSM driver and GMU
        # firmware are both loaded successfully. Without it Turnip/Freedreno cannot open
        # the device and every GL/VK call will crash.
        MSM_RENDER_NODE=""
        for node in /dev/dri/renderD*; do
            if [[ -c "$node" ]]; then
                # Check that this render node belongs to the msm/adreno driver
                DRIVER_LINK=$(readlink -f /sys/class/drm/$(basename "${node%D*}D$(basename $node | grep -o '[0-9]*')")/device/driver 2>/dev/null || true)
                MSM_RENDER_NODE="$node"
                break
            fi
        done

        if [[ -z "$MSM_RENDER_NODE" ]]; then
            log "WARNING: No DRI render node found — MSM GPU may not have initialised."
            log "         Falling back to software rendering. Check firmware at /lib/firmware/qcom/x1e80100/"
            log "         Required firmware: a690_sqe.fw, a690_gmu.bin"
            RENDER_MODE="sw"
            # Fall through to sw block below by re-executing that logic inline
            mkdir -p /etc/profile.d
            cat > /etc/profile.d/x1p-render.sh <<'EOF'
# Surface Pro 11 — Software Rendering Mode (hw requested but GPU not available)
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
unset VK_ICD_FILENAMES
EOF
            mkdir -p /etc/X11/xorg.conf.d
            cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "modesetting"
    Option      "AccelMethod" "none"
EndSection
EOF
        else
            log "MSM render node found: ${MSM_RENDER_NODE} — enabling Freedreno/Turnip"

            # Set Mesa to use freedreno (OpenGL) / turnip (Vulkan)
            mkdir -p /etc/profile.d
            cat > /etc/profile.d/x1p-render.sh <<'EOF'
# Surface Pro 11 — GPU Accelerated Mode (Adreno X1-85 / Freedreno + Turnip)
export LIBGL_ALWAYS_SOFTWARE=0
export GALLIUM_DRIVER=freedreno
export MESA_LOADER_DRIVER_OVERRIDE=freedreno
# Turnip Vulkan ICD — the .json filename is the Mesa-installed path for aarch64
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
EOF

            # X11 modesetting driver with Glamor (GPU-accelerated 2D via OpenGL ES)
            # DRI 3 is required for buffer sharing between the kernel and Mesa.
            # Do NOT set BusID here; let the modesetting driver auto-detect the MSM node.
            mkdir -p /etc/X11/xorg.conf.d
            cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "modesetting"
    Option      "AccelMethod" "glamor"
    Option      "DRI"         "3"
    Option      "kmsdev"      "/dev/dri/card0"
EndSection
EOF
        fi
        ;;

    sw)
        log "Configuring for Software Rendering (LLVMpipe)..."
        # MSM is loaded for display output, but Mesa uses CPU rendering
        modprobe msm 2>/dev/null || log "WARNING: msm module failed to load"
        
        mkdir -p /etc/profile.d
        cat > /etc/profile.d/x1p-render.sh <<'EOF'
# Surface Pro 11 — Software Rendering Mode (LLVMpipe)
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
unset VK_ICD_FILENAMES
EOF
        
        mkdir -p /etc/X11/xorg.conf.d
        cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "modesetting"
    Option      "AccelMethod" "none"
EndSection
EOF
        ;;

    safe)
        log "Configuring for Safe Mode (simpledrm + LLVMpipe)..."
        # msm is blacklisted via kernel cmdline; rely on simpledrm/efifb
        
        mkdir -p /etc/profile.d
        cat > /etc/profile.d/x1p-render.sh <<'EOF'
# Surface Pro 11 — Safe Mode
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
unset VK_ICD_FILENAMES
EOF
        
        mkdir -p /etc/X11/xorg.conf.d
        cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "fbdev"
EndSection
EOF
        ;;

    auto|*)
        log "Render mode '${RENDER_MODE}': probing GPU — will use hw if MSM node is present, sw otherwise..."
        # Probe for a DRI render node to decide between hw and sw automatically
        if [[ -c /dev/dri/renderD128 ]] || ls /dev/dri/renderD* &>/dev/null 2>&1; then
            log "DRI render node found — configuring for GPU hardware acceleration (auto)"
            mkdir -p /etc/profile.d
            cat > /etc/profile.d/x1p-render.sh <<'EOF'
# Surface Pro 11 — GPU Accelerated Mode (auto-detected)
export LIBGL_ALWAYS_SOFTWARE=0
export GALLIUM_DRIVER=freedreno
export MESA_LOADER_DRIVER_OVERRIDE=freedreno
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
EOF
            mkdir -p /etc/X11/xorg.conf.d
            cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "modesetting"
    Option      "AccelMethod" "glamor"
    Option      "DRI"         "3"
    Option      "kmsdev"      "/dev/dri/card0"
EndSection
EOF
        else
            log "No DRI render node found — configuring for software rendering (auto fallback)"
            mkdir -p /etc/profile.d
            cat > /etc/profile.d/x1p-render.sh <<'EOF'
# Surface Pro 11 — Software Rendering Mode (auto fallback — no GPU detected)
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
unset VK_ICD_FILENAMES
EOF
            mkdir -p /etc/X11/xorg.conf.d
            cat > /etc/X11/xorg.conf.d/20-gpu.conf <<'EOF'
Section "Device"
    Identifier  "Card0"
    Driver      "modesetting"
    Option      "AccelMethod" "none"
EndSection
EOF
        fi
        ;;
esac

# Make scripts executable
chmod +x /etc/profile.d/x1p-render.sh 2>/dev/null || true

# Log GPU info if available
if [[ -d /sys/class/drm ]]; then
    log "DRM devices:"
    ls -la /sys/class/drm/ | tee -a "$LOGFILE"
fi

if command -v lspci &>/dev/null; then
    log "PCIe VGA devices:"
    lspci | grep -i vga | tee -a "$LOGFILE" || true
fi

log "Render mode setup complete."
