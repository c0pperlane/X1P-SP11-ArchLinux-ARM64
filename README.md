# Arch Linux ARM64 for Surface Pro 11 (Snapdragon X Plus, 10-Core)

Native Arch Linux ARM64 for the Microsoft **Surface Pro 11** (Qualcomm Snapdragon
X Plus **X1P-64-100** / X1E80100, Adreno X1-85). Boots from USB or an external
NVMe; can live alongside your data via partition-mode flashing.

> Bringup project — expect rough edges. See `CLAUDE.md` for the detailed,
> always-current project notes.

## What you get

- **Kernel `6.17.0-sp11`** from [dwhinham/kernel-surface-pro-11](https://github.com/dwhinham/kernel-surface-pro-11)
  (`wip/x1e80100-6.17-sp11`) — carries the `x1e80100-microsoft-denali` DTB and the
  X1E80100/Surface-Aggregator patches that mainline lacks. (Mainline has only the
  Surface *Laptop 7* "romulus" DTBs, which is why a plain kernel.org build
  black-screens on the Pro 11.)
- **i3-wm** desktop (autologin as `alarm`)
- **Surface Aggregator** drivers (keyboard cover / touch) as modules
- **Firmware** via `linux-firmware-qcom` (build time) + `sp11-grab-fw` (runtime)

## Build

The image is built by **GitHub Actions** (`.github/workflows/build.yml`) and
uploaded as the artifact **`sp11-i3-image`** (`sp11-i3.img`, ~12 GB sparse). Push
to `main` (touching `scripts/`, `configs/`, `sp11-grab-fw.*`, `hooks/`, or the
workflow) or run it manually via *Actions → Build SP11 Image → Run workflow*.

To build locally (Linux / WSL2, as root):

```bash
sudo bash scripts/build-kernel.sh      # clones + builds the SP11 6.17 kernel
sudo bash scripts/build-usb-image.sh   # -> build/sp11-i3.img
```

`build-usb-image.sh` is self-contained: it creates the GPT image, extracts the
Arch Linux ARM rootfs, chroots in (via qemu when cross-building) to install i3 /
packages and the initramfs, and populates the ESP.

## Flash

Use the Windows GUI flasher (run as Administrator):

```
X1P-SP11-Flash.bat
```

- **Whole-disk mode** — for a blank USB stick: wipes the disk, writes the full image.
- **Partition mode** — writes only into chosen target partitions (ESP + ext4 root),
  leaving every other partition untouched. This is how Linux goes onto an external
  NVMe alongside your data. Lock your data partition (shown red), pick ESP/root
  targets, then *Set GPT types*. See `CLAUDE.md` → "Flash safety" for the details.

> The old CLI flashers are archived in `archive/old-flash-scripts.DO-NOT-RUN.zip`
> and must not be run — they did whole-disk `diskpart clean` + dd.

## First boot

1. Auto-grow expands the root partition to fill the disk.
2. i3 starts (login `alarm` / `alarm`; root `root` / `root`).
3. Plug in a USB-C Ethernet adapter, then: `sudo sp11-grab-fw`
   (fetches the Qualcomm display/DSP firmware for the Denali board).
4. Reboot → Wi-Fi (WCN7850 / ath12k) works.

> Booting from a **USB-attached** NVMe is treated as non-NVMe, so `sp11-grab-fw`
> leaves the **ADSP** firmware as `adsp_dtb.mbn.disabled` on purpose — enabling it
> on a USB boot can hang startup. Only rename it to `.mbn` on an **internally**
> attached NVMe.

### Boot entries (systemd-boot)

| Entry | Notes |
|-------|-------|
| `sp11-i3` (default) | normal graphical boot |
| `sp11-console` | multi-user (no X), recovery |
| `sp11-efifb` | `modprobe.blacklist=msm`, EFI framebuffer fallback |

Kernel cmdline keeps `clk_ignore_unused pd_ignore_unused` (required) and
`root=LABEL=ARCH_X1P_ROOT`.

## Repo layout

```
.
├── .github/workflows/build.yml   # CI: builds + uploads sp11-i3.img
├── scripts/
│   ├── build-kernel.sh           # clone + build the dwhinham SP11 6.17 kernel
│   ├── build-usb-image.sh        # build the full bootable image
│   ├── env.sh                    # shared build config
│   ├── X1P-SP11-Flash.ps1        # WinForms backend for the GUI flasher
│   └── read-ext4.* / readpath.*  # Windows helpers to peek at ext4 partitions
├── configs/kernel-config-fragment # merged onto the ALARM linux-aarch64 config
├── hooks/                        # pacman hooks (ESP/dtb upkeep)
├── skel/                         # optional rootfs overlay configs
├── sp11-grab-fw.{sh,bat}         # runtime Qualcomm firmware grabber
├── X1P-SP11-Flash.bat            # the flasher (double-click)
├── archive/                      # zipped old CLI flashers (do not run)
└── CLAUDE.md                     # detailed project notes
```

Firmware blobs and build artifacts are **not** committed (gitignored); the kernel
build regenerates them and `sp11-grab-fw` fetches the proprietary firmware at
runtime.

## License

Scaffolding provided as-is for development/education. Arch Linux ARM and the Linux
kernel are under their respective licenses. Qualcomm/Microsoft firmware is fetched
on-device for the hardware it shipped on and is not redistributed here.
