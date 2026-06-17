#!/bin/bash
# SP11 Arch Linux ARM64 — Full image build script
# Surface Pro 11 (Snapdragon X Plus X1P-64-100) with i3-wm
# Run inside WSL2 Ubuntu as root
#
# Output: /root/linux-surface-pro-11/build/sp11-i3.img (11GB, auto-expands on first boot)
# Flash:  scripts/flash-usb.ps1 (Windows PowerShell, run as Administrator)

set -e

source "$(dirname "$0")/env.sh"

# ── Config ───────────────────────────────────────────────────────────────────
B="${BUILD_DIR:-/root/linux-surface-pro-11/build}"
RTAR="${CACHE_DIR:-$B}/archlinuxarm-aarch64-latest.tar.gz"
OUT="$B/sp11-i3.img"
MNT=/mnt/sp11root
KVER="${KERNEL_VERSION:-6.17.0}-sp11"
MIRROR=nj.us.mirror.archlinuxarm.org
SIZE_MB=5120   # 5GB — auto-expands to full disk on first boot

MIRRORIP=$(getent hosts $MIRROR | awk '{print $1}' | head -1)
[ -z "$MIRRORIP" ] && { echo "DNS failed for $MIRROR"; exit 1; }
echo "Mirror: $MIRROR = $MIRRORIP   size=${SIZE_MB}MB"

# ── [1/6] Create GPT image ───────────────────────────────────────────────────
echo "=== [1/6] Create GPT image (ESP 512M + root) ==="
rm -f "$OUT"
truncate -s ${SIZE_MB}M "$OUT"
sgdisk -og "$OUT" >/dev/null
sgdisk -n 1:2048:+512M  -t 1:ef00 -c 1:EFI  "$OUT" >/dev/null
sgdisk -n 2:0:0          -t 2:8300 -c 2:ROOT "$OUT" >/dev/null

LOOP=$(losetup -fP --show "$OUT"); sleep 2; partprobe "$LOOP" 2>/dev/null || true; sleep 2
EFI=${LOOP}p1; ROOT=${LOOP}p2
mkfs.fat -F32 -n X1P_BOOT "$EFI" >/dev/null
mkfs.ext4 -q -L ARCH_X1P_ROOT "$ROOT"
mkdir -p "$MNT"; mount "$ROOT" "$MNT"
trap 'sync; umount -R "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null' EXIT

# ── [2/6] Extract rootfs + SP11 modules ──────────────────────────────────────
echo "=== [2/6] Extract rootfs + SP11 kernel modules ==="
bsdtar -xpf "$RTAR" -C "$MNT"
# The modules tarball is rooted at lib/modules/... but the rootfs is usr-merged
# (/lib -> usr/lib). --keep-directory-symlink makes tar extract THROUGH the
# /lib symlink instead of replacing it with a real dir — otherwise
# /lib/ld-linux-aarch64.so.1 disappears and the aarch64 chroot can't start.
tar xzf "$B/kernel-modules-${KVER}.tar.gz" -C "$MNT" --keep-directory-symlink

# ── [3/6] Base system config ─────────────────────────────────────────────────
echo "=== [3/6] Base config ==="

# fstab — writeback + async writes maximizes RAM buffering on USB
cat > "$MNT/etc/fstab" << 'EOF'
LABEL=ARCH_X1P_ROOT  /        ext4   defaults,noatime,data=writeback,commit=60,nobarrier,lazytime  0 1
LABEL=X1P_BOOT       /boot    vfat   ro,noatime,nofail                                            0 2
tmpfs                /tmp     tmpfs  defaults,noatime,nosuid,nodev,size=1G                          0 0
tmpfs                /var/tmp tmpfs  defaults,noatime,nosuid,nodev,size=512M                        0 0
EOF

# Mirror + DNS
echo "Server = http://$MIRROR/\$arch/\$repo" > "$MNT/etc/pacman.d/mirrorlist"
echo "$MIRRORIP $MIRROR" >> "$MNT/etc/hosts"
sed -i 's/^hosts:.*/hosts: files dns/' "$MNT/etc/nsswitch.conf" 2>/dev/null || true

# VM tuning — maximize RAM write buffer, minimize USB writes
cat > "$MNT/etc/sysctl.d/99-sp11-perf.conf" << 'EOF'
vm.swappiness = 10
vm.dirty_ratio = 80
vm.dirty_background_ratio = 60
vm.vfs_cache_pressure = 25
vm.dirty_expire_centisecs = 60000
vm.dirty_writeback_centisecs = 30000
vm.min_free_kbytes = 65536
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

# Journal to RAM — zero runtime writes to USB stick
mkdir -p "$MNT/etc/systemd/journald.conf.d"
cat > "$MNT/etc/systemd/journald.conf.d/ram.conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF

# zram — 60% of RAM as compressed swap
cat > "$MNT/etc/systemd/zram-generator.conf" << 'EOF'
[zram0]
zram-size = min(ram * 0.6, 6144)
compression-algorithm = zstd
EOF

# I/O scheduler — mq-deadline for USB block devices
cat > "$MNT/etc/udev/rules.d/60-sp11-ioscheduler.rules" << 'EOF'
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/nr_requests}="32"
EOF

# pacman — parallel downloads, block linux-aarch64, RAM download cache
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$MNT/etc/pacman.conf"
sed -i 's/^#IgnorePkg.*/IgnorePkg = linux-aarch64 linux-aarch64-headers/' "$MNT/etc/pacman.conf"
# Downloads land in /tmp (tmpfs = RAM), then get written to disk via writeback ext4
sed -i '/^\[options\]/a CacheDir = /tmp/pacman-pkg/\nCacheDir = /var/cache/pacman/pkg/' "$MNT/etc/pacman.conf"

# Tools
# Missing sp11-grab-fw.sh in git repository
if [ -f "$PROJECT_ROOT/sp11-grab-fw.sh" ]; then
    install -m755 "$PROJECT_ROOT/sp11-grab-fw.sh" "$MNT/usr/local/sbin/sp11-grab-fw"
elif [ -f "$PROJECT_ROOT/scripts/sp11-grab-fw.sh" ]; then
    install -m755 "$PROJECT_ROOT/scripts/sp11-grab-fw.sh" "$MNT/usr/local/sbin/sp11-grab-fw"
else
    echo "Warning: sp11-grab-fw.sh not found, skipping installation."
fi

# Compositor toggle
cat > "$MNT/usr/local/bin/compositor" << 'EOF'
#!/bin/bash
case "$1" in
  start)  picom --no-vsync --daemon && echo "compositor started" ;;
  stop)   pkill picom && echo "compositor stopped" || echo "not running" ;;
  toggle) pgrep picom > /dev/null && pkill picom && echo "stopped" || { picom --no-vsync --daemon && echo "started"; } ;;
  *)      echo "usage: compositor [start|stop|toggle]" ;;
esac
EOF
chmod +x "$MNT/usr/local/bin/compositor"

# First-boot auto-grow (expands root to full disk size)
cat > "$MNT/usr/local/sbin/x1p-grow" << 'EOF'
#!/bin/bash
[ -f /var/lib/x1p-grown ] && exit 0
RP=$(findmnt -no SOURCE /); DISK=/dev/$(lsblk -no pkname "$RP"); PN=$(echo "$RP"|grep -o '[0-9]*$')
sgdisk -e "$DISK" 2>/dev/null || true
growpart "$DISK" "$PN" 2>/dev/null || true
partx -u "$DISK" 2>/dev/null || partprobe "$DISK" 2>/dev/null || true
resize2fs "$RP" 2>/dev/null || true
touch /var/lib/x1p-grown
EOF
chmod +x "$MNT/usr/local/sbin/x1p-grow"
cat > "$MNT/etc/systemd/system/x1p-grow.service" << 'EOF'
[Unit]
Description=Grow root partition to full disk (first boot only)
ConditionPathExists=!/var/lib/x1p-grown
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/x1p-grow
[Install]
WantedBy=multi-user.target
EOF

# ESP guard — boot entries are HARDCODED here, no backup directory needed.
# /boot is mounted ro normally; guard remounts rw to restore, then back to ro.
# Runs: (a) at every boot via systemd, (b) after every pacman transaction via hook.
CMN_OPT="root=LABEL=ARCH_X1P_ROOT rw rootfstype=ext4 clk_ignore_unused pd_ignore_unused"
cat > "$MNT/usr/local/sbin/sp11-esp-guard" << EOF
#!/bin/bash
BOOT=/boot
LOG=/var/log/sp11-esp-guard.log
echo "\$(date) sp11-esp-guard: checking..." >> "\$LOG"

# Ensure /boot is mounted (it might be ro — that's fine, we'll remount as needed)
if ! mountpoint -q "\$BOOT"; then
    mount "\$BOOT" 2>/dev/null || { echo "\$(date) /boot not mountable — skip" >> "\$LOG"; exit 0; }
fi

# Hardcoded correct content for every boot entry — no backup dir needed
declare -A ENTRIES
ENTRIES[sp11-i3.conf]="title SP11 - i3 Desktop
linux /Image
initrd /initramfs.img
devicetree /dtbs/qcom/x1e80100-microsoft-denali.dtb
options $CMN_OPT loglevel=4"

ENTRIES[sp11-console.conf]="title SP11 - Console (recovery)
linux /Image
initrd /initramfs.img
devicetree /dtbs/qcom/x1e80100-microsoft-denali.dtb
options $CMN_OPT loglevel=7 systemd.unit=multi-user.target"

ENTRIES[sp11-efifb.conf]="title SP11 - efifb fallback
linux /Image
initrd /initramfs.img
devicetree /dtbs/qcom/x1e80100-microsoft-denali.dtb
options $CMN_OPT loglevel=7 modprobe.blacklist=msm systemd.unit=multi-user.target"

LOADER="default sp11-i3.conf
timeout 8
console-mode max
editor yes"

FIXED=0

# Check each entry — if missing, empty, or missing the required boot param → restore
for name in "\${!ENTRIES[@]}"; do
    f="\$BOOT/loader/entries/\$name"
    if [ ! -f "\$f" ] || [ ! -s "\$f" ] || ! grep -q "clk_ignore_unused" "\$f" 2>/dev/null; then
        echo "\$(date) CORRUPT/MISSING: \$name — restoring" >> "\$LOG"
        mount -o remount,rw "\$BOOT" 2>/dev/null || true
        mkdir -p "\$BOOT/loader/entries"
        printf '%s\n' "\${ENTRIES[\$name]}" > "\$f"
        FIXED=1
    fi
done

if [ ! -s "\$BOOT/loader/loader.conf" ]; then
    echo "\$(date) loader.conf missing — restoring" >> "\$LOG"
    mount -o remount,rw "\$BOOT" 2>/dev/null || true
    printf '%s\n' "\$LOADER" > "\$BOOT/loader/loader.conf"
    FIXED=1
fi

if [ \$FIXED -eq 1 ]; then
    sync
    echo "\$(date) ESP REPAIRED — entries were corrupted" >> "\$LOG"
    # Lock /boot back to read-only
    mount -o remount,ro "\$BOOT" 2>/dev/null || true
else
    echo "\$(date) ESP OK" >> "\$LOG"
fi
EOF
chmod +x "$MNT/usr/local/sbin/sp11-esp-guard"
cat > "$MNT/etc/systemd/system/sp11-esp-guard.service" << 'EOF'
[Unit]
Description=SP11 ESP integrity guard
Before=display-manager.service
After=local-fs.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sp11-esp-guard
RemainAfterExit=yes
[Install]
WantedBy=sysinit.target
EOF
mkdir -p "$MNT/etc/pacman.d/hooks"
cat > "$MNT/etc/pacman.d/hooks/sp11-esp-guard.hook" << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *
[Action]
Description = SP11: Checking ESP boot entries...
When = PostTransaction
Exec = /usr/local/sbin/sp11-esp-guard
EOF

# ── [4/6] Chroot install ──────────────────────────────────────────────────────
echo "=== [4/6] Chroot: install packages ==="
mount -t proc proc "$MNT/proc"
mount --rbind /sys  "$MNT/sys"
mount --rbind /dev  "$MNT/dev"
mount -t tmpfs tmpfs "$MNT/run"

cat > "$MNT/root/chroot.sh" << 'CH'
set -e
export LANG=C
rm -f /var/lib/pacman/db.lck
# pacman 7's download sandbox (Landlock + 'alpm' user) is unsupported under
# qemu-user emulation in this chroot; disable it so -Syu can sync/download.
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinuxarm
pacman -D --asexplicit linux-firmware mkinitcpio
pacman -Rcuns --noconfirm linux-aarch64 || true

pacman -Syu --noconfirm --needed \
  i3-wm i3status dunst picom rofi feh \
  xorg-server xorg-xinit xorg-xrdb xterm \
  lightdm lightdm-gtk-greeter \
  firefox \
  mesa \
  ttf-dejavu noto-fonts \
  networkmanager iw iwd \
  profile-sync-daemon earlyoom \
  zram-generator \
  sudo git jq cabextract \
  gptfdisk cloud-guest-utils \
  linux-firmware-qcom mkinitcpio \
  terminus-font

pacman -Scc --noconfirm || true

systemctl enable NetworkManager lightdm x1p-grow sp11-esp-guard
systemctl enable systemd-zram-setup@zram0.service earlyoom
systemctl set-default graphical.target
systemctl disable sddm 2>/dev/null || true

echo 'root:root' | chpasswd
echo 'alarm:alarm' | chpasswd
usermod -aG wheel alarm 2>/dev/null || true
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

# lightdm autologin → i3
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf << 'LDM'
[Seat:*]
autologin-user=alarm
autologin-user-timeout=0
user-session=i3
greeter-session=lightdm-gtk-greeter
LDM
cat > /etc/lightdm/lightdm-gtk-greeter.conf << 'GRT'
[greeter]
theme-name = Adwaita-dark
font-name = DejaVu Sans 10
GRT

# mkinitcpio — SP11 PHY modules required for USB root mount
sed -i 's/^MODULES=(.*/MODULES=(tcsrcc-x1e80100 phy-qcom-qmp-pcie phy-qcom-qmp-usb phy-qcom-qmp-usbc phy-qcom-eusb2-repeater phy-snps-eusb2 phy-qcom-qmp-combo surface-hid surface-aggregator surface-aggregator-registry surface-aggregator-hub)/' /etc/mkinitcpio.conf
mkinitcpio -k 6.17.0-sp11 -g /boot/initramfs-sp11.img

grep -q '^FONT=' /etc/vconsole.conf 2>/dev/null || echo FONT=ter-132n >> /etc/vconsole.conf
pacman -Q i3-wm lightdm firefox earlyoom profile-sync-daemon | sed 's/^/  /'
ls -lh /boot/initramfs-sp11.img
echo CH_OK
CH

# Cross-arch chroot needs a static qemu inside the rootfs when binfmt lacks the
# F (fix-binary) flag (x86 CI runners, some WSL setups). No-op on native aarch64.
QEMU_STATIC="$(command -v qemu-aarch64-static || true)"
[ -n "$QEMU_STATIC" ] && cp "$QEMU_STATIC" "$MNT/usr/bin/"

chroot "$MNT" /bin/bash /root/chroot.sh

# Don't ship the foreign qemu binary in the final image.
[ -n "$QEMU_STATIC" ] && rm -f "$MNT/usr/bin/$(basename "$QEMU_STATIC")"

# ── [5/6] User dotfiles ───────────────────────────────────────────────────────
echo "=== [5/6] User dotfiles ==="
H="$MNT/home/alarm"
mkdir -p "$H/.config/i3" "$H/.config/i3status" "$H/.config/dunst" \
         "$H/.config/picom" "$H/.config/gtk-3.0" "$H/.config/gtk-4.0" \
         "$H/.mozilla/firefox/sp11.default"

cat > "$H/.config/i3/config" << 'I3CFG'
set $mod Mod4
font pango:DejaVu Sans Mono 10
client.focused          #4c7899 #285577 #ffffff #2e9ef4 #285577
client.focused_inactive #333333 #1e1e1e #888888 #484e50 #1e1e1e
client.unfocused        #333333 #1a1a1a #888888 #292d2e #1a1a1a
client.urgent           #2f343a #900000 #ffffff #900000 #900000
client.background       #1a1a1a
default_border pixel 2
gaps inner 6
gaps outer 2
exec --no-startup-id setxkbmap us
exec --no-startup-id dunst
exec --no-startup-id picom --no-vsync --daemon
exec --no-startup-id feh --bg-solid "#1a1a1a"
bindsym $mod+Return exec xterm
bindsym $mod+d      exec rofi -show run
bindsym $mod+b      exec firefox
bindsym $mod+q      kill
bindsym $mod+f      fullscreen toggle
bindsym $mod+c      exec compositor toggle
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit?' -B 'Yes' 'i3-msg exit'"
bindsym $mod+Shift+r restart
bindsym $mod+h split h
bindsym $mod+v split v
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+Left  focus left
bindsym $mod+Right focus right
bindsym $mod+Up    focus up
bindsym $mod+Down  focus down
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Right move right
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Down  move down
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4
bindsym $mod+Shift+5 move container to workspace 5
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute   @DEFAULT_SINK@ toggle
bar {
    status_command i3status
    position top
    colors {
        background #1a1a1a
        statusline #dddddd
        separator  #444444
        focused_workspace  #285577 #285577 #ffffff
        active_workspace   #333333 #1e1e1e #888888
        inactive_workspace #1a1a1a #1a1a1a #888888
        urgent_workspace   #900000 #900000 #ffffff
    }
}
I3CFG

cat > "$H/.config/i3status/config" << 'I3ST'
general {
    colors = true
    color_good     = "#88c070"
    color_degraded = "#f0c674"
    color_bad      = "#cc6666"
    interval = 5
}
order += "wireless _first_"
order += "ethernet _first_"
order += "cpu_usage"
order += "memory"
order += "tztime local"
wireless _first_ { format_up = "W: %essid %quality" format_down = "W: off" }
ethernet _first_ { format_up = "E: %ip" format_down = "" }
cpu_usage        { format = "CPU: %usage" }
memory           { format = "RAM: %used/%total" threshold_degraded = "10%" }
tztime local     { format = "%H:%M %d.%m.%Y" }
I3ST

cat > "$H/.config/dunst/dunstrc" << 'DUNST'
[global]
    monitor = 0
    follow = mouse
    width = 300
    height = 100
    origin = top-right
    offset = 10x30
    font = DejaVu Sans Mono 10
    frame_color = "#444444"
    separator_color = "#444444"
    background = "#1a1a1a"
    foreground = "#dddddd"
    timeout = 5
[urgency_normal]
    background = "#1e1e2e"
    foreground = "#cdd6f4"
    timeout = 5
[urgency_critical]
    background = "#900000"
    foreground = "#ffffff"
    timeout = 0
DUNST

cat > "$H/.config/picom/picom.conf" << 'PICOM'
backend = "xrender";
vsync = false;
shadow = true;
shadow-radius = 7;
shadow-opacity = 0.5;
fading = false;
PICOM

cat > "$H/.config/gtk-3.0/settings.ini" << 'GTK'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-font-name=DejaVu Sans 10
gtk-application-prefer-dark-theme=1
GTK
cp "$H/.config/gtk-3.0/settings.ini" "$H/.config/gtk-4.0/settings.ini"

cat > "$H/.Xresources" << 'XRES'
XTerm*background:        #1a1a1a
XTerm*foreground:        #dddddd
XTerm*faceName:          DejaVu Sans Mono
XTerm*faceSize:          11
XTerm*scrollBar:         false
XTerm*selectToClipboard: true
XTerm*fastScroll:        true
XTerm*saveLines:         2000
XRES

printf '#!/bin/sh\nxrdb -merge ~/.Xresources\nsetxkbmap us\nexec i3\n' > "$H/.xinitrc"
chmod +x "$H/.xinitrc"

cat >> "$H/.bashrc" << 'BASH'
alias cs='compositor stop'
alias cx='compositor start'
alias ct='compositor toggle'
BASH

cat > "$H/.mozilla/firefox/sp11.default/user.js" << 'UJS'
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.memory.capacity", 262144);
user_pref("browser.sessionstore.interval", 60000);
user_pref("browser.sessionstore.max_tabs_undo", 5);
user_pref("ui.systemUsesDarkTheme", 1);
user_pref("browser.in-content.dark-mode.enabled", true);
user_pref("general.smoothScroll", true);
UJS

printf '[Install]\nDefaultProfile=sp11.default\n[Profile0]\nName=default\nIsRelative=1\nPath=sp11.default\nDefault=1\n' \
    > "$H/.mozilla/firefox/profiles.ini"
printf 'BROWSERS=(firefox)\n' > "$H/.config/psd.conf"

cat > "$H/CLAUDE.md" << 'CLDMD'
# SP11 Arch Linux — Claude Rules

## HARD: Never install x86-only packages
ARM64 system — x86 packages destroy glibc → full reflash needed.
- Discord → webcord (AUR aarch64 only)
- Spotify → spotify-launcher or ncspot

## HARD: Never touch kernel/mkinitcpio/boot params
clk_ignore_unused pd_ignore_unused MUST stay in boot cmdline.
Kernel = 6.17.0-sp11 (dwhinham). Never install linux-aarch64.
Boot entries backed up at /var/lib/sp11-esp-backup/ — sp11-esp-guard restores on every pacman transaction.

## Compositor
compositor start / stop / toggle  |  Super+c in i3  |  aliases: cs / cx / ct
Runs picom --no-vsync (no added input latency)

## WiFi setup (first time)
Plug in USB-C ethernet adapter, then: sudo sp11-grab-fw
CLDMD

chown -R 1000:1000 "$H"

# ── [6/6] Populate ESP ────────────────────────────────────────────────────────
echo "=== [6/6] Populate ESP ==="
SDBOOT="$MNT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
IRD="$MNT/boot/initramfs-sp11.img"
KIMG="$B/boot/Image"
DENALI="$B/boot/dtbs/x1e80100-microsoft-denali.dtb"

for d in ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/dtbs ::/dtbs/qcom; do
    mmd -i "$EFI" "$d" 2>/dev/null || true
done
mcopy -i "$EFI" -D o -o "$SDBOOT" ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "$EFI" -D o -o "$KIMG"   ::/Image
mcopy -i "$EFI" -D o -o "$IRD"    ::/initramfs.img
mcopy -i "$EFI" -D o -o "$DENALI" ::/dtbs/qcom/x1e80100-microsoft-denali.dtb

T=/tmp/esp_e; rm -rf "$T"; mkdir -p "$T/entries"
printf 'default sp11-i3.conf\ntimeout 8\nconsole-mode max\neditor yes\n' > "$T/loader.conf"
CMN="root=LABEL=ARCH_X1P_ROOT rw rootfstype=ext4 clk_ignore_unused pd_ignore_unused"
printf 'title SP11 - i3 Desktop\nlinux /Image\ninitrd /initramfs.img\ndevicetree /dtbs/qcom/x1e80100-microsoft-denali.dtb\noptions %s loglevel=4\n' "$CMN" > "$T/entries/sp11-i3.conf"
printf 'title SP11 - Console (recovery)\nlinux /Image\ninitrd /initramfs.img\ndevicetree /dtbs/qcom/x1e80100-microsoft-denali.dtb\noptions %s loglevel=7 systemd.unit=multi-user.target\n' "$CMN" > "$T/entries/sp11-console.conf"
printf 'title SP11 - efifb fallback\nlinux /Image\ninitrd /initramfs.img\ndevicetree /dtbs/qcom/x1e80100-microsoft-denali.dtb\noptions %s loglevel=7 modprobe.blacklist=msm systemd.unit=multi-user.target\n' "$CMN" > "$T/entries/sp11-efifb.conf"
mcopy -i "$EFI" -D o -o "$T/loader.conf" ::/loader/loader.conf
for e in sp11-i3 sp11-console sp11-efifb; do
    mcopy -i "$EFI" -D o -o "$T/entries/$e.conf" ::/loader/entries/$e.conf
done
fatlabel "$EFI" X1P_BOOT 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
sync
umount "$MNT/run" 2>/dev/null; umount -R "$MNT/dev"; umount -R "$MNT/sys"
umount "$MNT/proc"; umount "$MNT"; losetup -d "$LOOP"; trap - EXIT

ls -lh "$OUT"
echo "BUILD_SP11_DONE — flash: scripts/flash-usb.ps1"
