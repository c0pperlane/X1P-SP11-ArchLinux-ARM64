# Arch Linux ARM64 for Surface Pro 11 (Snapdragon X Plus 10-Core)

> **Experimental Native Port** for Microsoft Surface Pro 11 powered by the Qualcomm Snapdragon X Plus (X1P-64-100 / 10-core Oryon) with full iGPU (Adreno X1-85) acceleration support and secondary CPU software rendering fallback.

## Overview

This project provides a complete build system to create a bootable USB stick that runs Arch Linux natively on the Surface Pro 11 ARM64 platform. **All Qualcomm firmware has been extracted directly from the Windows driver store on this device** — no external firmware sources are used.

### Key Features

- **Linux Kernel 6.13+** with Snapdragon X1E80100 / X1P-64-100 device tree support
- **Adreno X1-85 iGPU acceleration** via Mesa Freedreno (Turnip Vulkan + OpenGL ES)
- **Bootloader selection** between GPU hardware acceleration and software rendering (LLVMpipe)
- **Live USB + Installer** — boot directly from USB or install to internal NVMe
- **Dual-boot friendly** — does not touch internal storage unless explicitly installed
- **Local firmware extraction** — GPU, Wi-Fi, Bluetooth, DSP, Camera, Video firmware from Windows DriverStore

## Project Structure

```
.
├── build/                          # Build artifacts (images, kernels, tarballs)
├── cache/                          # Downloaded tarballs
├── configs/                        # Bootloader, kernel, and initramfs configs
│   ├── kernel-config-fragment      # Extra kernel options for X1P/X1E
│   ├── mkinitcpio.conf             # Initramfs generation config
│   └── systemd-boot/               # Bootloader entries
│       ├── loader.conf
│       └── entries/
│           ├── arch-x1p-gpu.conf       # GPU Accelerated
│           ├── arch-x1p-software.conf  # Software Rendering
│           ├── arch-x1p-safe.conf      # Safe Mode
│           └── arch-x1p-debug.conf     # Debug Shell
├── docs/                           # Additional documentation
├── firmware/                       # Extracted Qualcomm firmware
│   └── qcom/x1e80100/
│       ├── adsp/                   # Audio DSP firmware + libs
│       ├── bt/                     # Bluetooth firmware
│       ├── camera/                 # Camera ISP firmware
│       ├── cdsp/                   # Compute DSP firmware
│       ├── gpu/                    # GPU/Display microcode
│       ├── video/                  # Video encoder/decoder
│       └── wlan/                   # Wi-Fi board data + firmware
├── patches/                        # Kernel and Mesa patches (if needed)
├── scripts/                        # Build automation
│   ├── build-all.sh                # Master build pipeline
│   ├── build-kernel.sh             # Download, configure, build kernel
│   ├── build-rootfs.sh             # Assemble Arch Linux ARM rootfs
│   ├── build-initramfs.sh          # Build initramfs
│   ├── build-usb-image.sh          # Generate flashable USB image
│   ├── extract-firmware.sh         # Extract firmware from Windows
│   └── flash-usb.sh                # Flash image to USB device
├── skel/                           # Skeleton files overlay for rootfs
│   ├── etc/
│   │   ├── dracut.conf.d/x1p.conf
│   │   ├── modprobe.d/x1p-gpu.conf
│   │   ├── profile.d/x1p-render.sh
│   │   ├── systemd/system/x1p-render-setup.service
│   │   └── X11/xorg.conf.d/20-gpu.conf
│   └── usr/local/bin/
│       ├── install-to-nvme.sh      # Internal SSD installer
│       └── x1p-render-setup.sh     # GPU/SW render boot config
└── README.md                       # This file
```

## Quick Start

### Prerequisites

You need a **Linux build environment** (WSL2, VM, or native ARM64 machine) with:

- `aarch64-linux-gnu-gcc` (cross-compiler) **or** native ARM64 toolchain
- `bc`, `bison`, `flex`, `openssl`, `libssl-dev`
- `dtc` (device tree compiler)
- `sfdisk`, `mkfs.fat`, `mkfs.ext4`, `parted`
- `arch-install-scripts` (for `arch-chroot`)

> **Windows Users:** Run these scripts inside **WSL2 (Ubuntu/Arch)**. MSYS2 alone cannot build the Linux kernel.

### 1. Extract Firmware (already done on this device!)

```bash
./scripts/extract-firmware.sh
```

**Result:** All Qualcomm firmware is now in `firmware/qcom/x1e80100/` — GPU, Wi-Fi (WCN785x), Bluetooth, ADSP, CDSP, camera, video.

### 2. Build Everything

```bash
./scripts/build-all.sh [image_size]
# Example:
./scripts/build-all.sh 16G
```

This runs the full pipeline:
1. Extract firmware
2. Build kernel (`Image.gz` + modules + DTBs)
3. Build rootfs (Arch Linux ARM aarch64 + Mesa + packages)
4. Build initramfs
5. Assemble USB disk image

### 3. Flash to USB

```bash
# List your USB device first
lsblk

# Flash it (DESTRUCTIVE — triple-check the device!)
sudo ./scripts/flash-usb.sh /dev/sdX
```

## Bootloader Menu

When booting the USB on Surface Pro 11, **systemd-boot** presents:

| Entry | Description |
|-------|-------------|
| **Arch Linux ARM — GPU Accelerated** | Full Adreno X1-85 hardware acceleration via Mesa Freedreno |
| **Arch Linux ARM — Software Rendering** | MSM display driver loaded, but Mesa forced to LLVMpipe |
| **Arch Linux ARM — Safe Mode** | GPU kernel modules blacklisted; simpledrm fallback + LLVMpipe |
| **Arch Linux ARM — Debug Shell** | Early debug shell with verbose logging |

**Boot method:** Hold **Volume Down + Power** on the Surface to access the UEFI boot menu, select USB.

## GPU vs Software Rendering

The Surface Pro 11's Adreno X1-85 is supported in kernel ≥6.11 and Mesa ≥24.2. During bringup:

1. **GPU Accelerated** — Kernel loads `msm` → Mesa uses `freedreno` (OpenGL) / `turnip` (Vulkan)
2. **Software Rendering** — Kernel loads `msm` for display → Mesa uses `llvmpipe` via `LIBGL_ALWAYS_SOFTWARE=1`
3. **Safe Mode** — `msm` blacklisted → `simpledrm` provides framebuffer → Mesa `llvmpipe`

The `x1p-render-setup.service` runs at boot, reads the `x1p.render=` kernel parameter, and configures X11/Wayland/Mesa accordingly. Logs are saved to `/var/log/x1p-render.log`.

## Installing to Internal NVMe

Once the live USB is running stably:

```bash
sudo install-to-nvme
```

This interactively:
- Partitions the NVMe (GPT: ESP, Boot, Root)
- Copies the rootfs and kernel
- Installs systemd-boot
- Supports **dual-boot with Windows** (manual partition option)

## Firmware Inventory (Extracted from Windows DriverStore)

| Subsystem | Files | Key Components |
|-----------|-------|----------------|
| **GPU/Display** | `qcdxkmbase8380.bin`, `qcdxkmsuc8380.mbn`, `qcvss8380.mbn`, `qcav1e8380.mbn` | GPU ucode, video subsystem, AV1 encoder |
| **Wi-Fi** | `wlanfw20.mbn`, `bdwlan*.elf`, `phy_ucode20.elf` | WCN785x firmware, board data |
| **Bluetooth** | `bsrc_bt.bin`, `hmtnv20.bin` | BT controller firmware |
| **ADSP** | `qcadsp8380.mbn`, `adspr.jsn`, `adsp_dtbs.elf` + 40+ libs | Audio DSP + codec modules |
| **CDSP** | `qccdsp8380.mbn` | Compute DSP |
| **Camera** | `CAMERA_ICP.mbn`, `C*.bin`, `IR*.bin` | ISP firmware |
| **Video** | `evass.mbn` | EVA/video accelerator |

Total: **126 files, ~80MB** extracted directly from `C:\Windows\System32\DriverStore\FileRepository\`.

## Development Workflow

1. **Iterate locally** in this project directory
2. **Rebuild** kernel/rootfs as needed (`./scripts/build-kernel.sh`, etc.)
3. **Regenerate** the USB image (`./scripts/build-usb-image.sh`)
4. **Flash and test** on the Surface Pro 11
5. **Capture logs** (`journalctl`, `dmesg`, `/var/log/x1p-render.log`) and refine

## Known Issues & Notes

- **UEFI Secure Boot:** Must be disabled on Surface Pro 11 to boot custom kernels.
- **Device Tree:** X1P-64-100 uses the X1E80100 device tree family. DTB is selected automatically.
- **Firmware formats:** Some Windows `.mbn`/`.bin` files may require format conversion or specific Linux driver support to load. This is a bringup project — expect trial and error.
- **Audio:** DSP audio support is experimental; expect HDMI/DP audio before onboard speakers.

## Resources

- [Arch Linux ARM](https://archlinuxarm.org/)
- [Linux Kernel — Qualcomm X1E80100](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/arm64/boot/dts/qcom/x1e80100.dtsi)
- [Mesa Freedreno Wiki](https://docs.mesa3d.org/drivers/freedreno.html)
- [Surface Pro 11 UEFI Boot](https://learn.microsoft.com/surface/secure-boot)

## License

This project scaffolding is provided as-is for educational and development purposes. Arch Linux ARM and the Linux kernel are governed by their respective licenses. Firmware files extracted from Windows are property of Qualcomm/Microsoft and are used here solely for hardware enablement on the device they were originally installed on.
