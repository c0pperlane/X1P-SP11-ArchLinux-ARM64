# SP11 Arch Linux ARM64 — Project Context

Surface Pro 11 (Snapdragon X Plus X1P-64-100, 10-core) booting Arch Linux ARM64 from USB.

## Hard Rules — Never Break

1. **No x86 packages on the ARM64 system** — destroys glibc, requires full reflash
   - Discord → webcord (AUR, aarch64)
   - Spotify → spotify-launcher or ncspot
   - Always verify `Architecture: any` or `aarch64` before installing

2. **Never touch kernel config or mkinitcpio MODULES** — wrong changes = instant black screen
   - Kernel: `6.17.0-sp11` (dwhinham/linux-surface-pro-11)
   - Boot params `clk_ignore_unused pd_ignore_unused` are REQUIRED, never remove
   - dispcc/gpucc must stay as modules (`=m`), never built-in (`=y`)

3. **ESP is protected by sp11-esp-guard** — runs after every pacman transaction
   - Backup at `/var/lib/sp11-esp-backup/`
   - Log at `/var/log/sp11-esp-guard.log`

## System Info

- **Kernel**: 6.17.0-sp11 (dwhinham/linux-surface-pro-11)
- **DTB**: x1e80100-microsoft-denali.dtb
- **Desktop**: i3-wm + lightdm autologin as `alarm`
- **Users**: alarm:alarm / root:root
- **Boot entries**: arch-x1p-console (default), arch-x1p-rescue, arch-x1p-gpu, arch-x1p-safe, arch-x1p-debug, arch-x1p-software, arch-x1p-powersave

## Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-usb-image.sh` | Full image build from scratch (run in WSL as root) |
| `X1P-SP11-Flash.bat` | **The only flasher.** Double-click → GUI with disk/partition view, manual select + type-FLASH confirm |
| `scripts/X1P-SP11-Flash.ps1` | WinForms backend for the GUI flasher |

> ⚠️ **All old CLI flashers are archived in `archive/old-flash-scripts.DO-NOT-RUN.zip` and must NOT be extracted/run.** They did whole-disk `diskpart clean` + dd with only a `BusType=USB` guard — and the external projects-NVMe reports `BusType=USB`, so they would have wiped it. Use only the GUI tool.

### Flash safety (X1P-SP11-Flash)
Two modes:

**(1) Whole-disk** — wipes the whole disk and writes the full GPT image (ESP/FAT32 `X1P_BOOT` + ext4 `ARCH_X1P_ROOT`). For blank USB sticks.
- Internal disks (BusType ≠ USB/SD) are shown but never flashable.
- Protected disks: ids in `scripts/protected-disks.txt` (gitignored) are hard-blocked. Mark the projects-NVMe (Realtek RTL9210B-CG, GPT GUID `1b611e6e-…`) Protected.
- After flashing, drive letters are stripped from the new FAT32 ESP (no letter pile-up).

**(2) Partition** — writes ONLY into chosen target partitions; every other partition is untouched. This is how Linux goes onto the projects-NVMe alongside data.
- **Boundary guarantee**: writes go through a per-partition volume handle (`\\.\Volume{GUID}`) opened with `FSCTL_LOCK_VOLUME`+`FSCTL_DISMOUNT_VOLUME`. Windows bounds every write to that partition's extent (verified: `IOCTL_DISK_GET_LENGTH_INFO` == `partition.Size`). A different partition is a different volume device the tool never opens → physically unreachable.
- **No** `diskpart clean`, **no** `\\.\PhysicalDrive` write, **no** GPT/partition-table write in this mode.
- Source ESP/ext4 byte ranges are parsed from the image's own GPT (`Get-ImagePartitions`). Verified ranges: ESP off=1048576 size=511MB; root off=536870912 size=7679MB.
- Excluded ("locked") partitions: GUIDs in `scripts/locked-partitions.txt` (gitignored), shown red with a lock struck through (owner-drawn tree); can never be a target. Default is ignore-all; only ROOT/ESP targets you set are written.
- `x1p-grow` is safe here: `growpart` only expands into trailing free space and respects partition boundaries — it cannot overwrite a preceding data partition. Target ext4 partition must be ≥ 7679MB.

## WSL Image Path
`\\wsl$\<YOUR_DISTRO>\root\linux-surface-pro-11\build\sp11-i3.img`

## First Boot Checklist
1. Auto-grow runs → disk expands to full size
2. LightDM → autologin alarm → i3 starts
3. Plug USB-C ethernet → `sudo sp11-grab-fw` → WiFi firmware installed
4. Reboot → WiFi works

## i3 Keybinds
- `Super+Return` → xterm
- `Super+d` → rofi launcher
- `Super+b` → Firefox
- `Super+c` → compositor toggle
- `cs/cx/ct` → compositor stop/start/toggle

## Performance Tuning (already applied)
- `data=writeback,commit=60,nobarrier,lazytime` on ext4
- `vm.dirty_ratio=80`, `dirty_writeback=15000` — max RAM buffering
- Journal volatile (RAM only)
- `/tmp` and `/var/tmp` on tmpfs
- zram 60% of RAM, zstd
- Firefox cache fully in RAM (no disk cache)
- profile-sync-daemon for Firefox profile
- mq-deadline I/O scheduler for USB

## NVMe Migration (planned)
500GB external NVMe via USB-C (10 Gbps) — just run `scripts/build-usb-image.sh` again,
flash to NVMe. All config is in the build script, nothing manual needed.
