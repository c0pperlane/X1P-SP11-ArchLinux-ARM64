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
- **Boot entries**: sp11-plasma (default), sp11-console (recovery), sp11-efifb (no msm)

## Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-usb-image.sh` | Full image build from scratch (run in WSL as root) |
| `flash.bat` | Interactive USB flasher — double-click, pick drive, flash |
| `scripts/flash-select.ps1` | PowerShell backend for flash.bat |
| `scripts/_autoflash.ps1` | No-prompt flash (hardcode disk number at top) |

## WSL Image Path
`\\wsl$\<YOUR_DISTRO>\root\linux-surface-pro-11\build\sp11-plasma.img`

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
