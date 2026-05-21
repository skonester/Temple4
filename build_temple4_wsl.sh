#!/usr/bin/env bash
set -euo pipefail

# Temple4 ISO remaster for WSL.
# Canonical release builds should use ./full_build_wsl.sh, which enables the
# runtime-lite profile and writes Temple4-runtime-lite.iso.
# Direct execution defaults to quick mode for low-level smoke/debug builds.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/wsl_common.sh"

SOURCE_DIR="${SOURCE_DIR:-$SCRIPT_DIR/Temple4}"
CIA_DIR="${CIA_DIR:-$SCRIPT_DIR/CIA Protected}"
WORK_DIR="${WORK_DIR:-$HOME/temple4_work}"
ISO_ROOT="${ISO_ROOT:-$WORK_DIR/iso_root}"
LIVE_ROOT="${LIVE_ROOT:-$WORK_DIR/squashfs-root}"
OUTPUT_ISO="${OUTPUT_ISO:-$WORK_DIR/Temple4-quick.iso}"
ISOHYBRID_MBR="${ISOHYBRID_MBR:-}"
REPACK_LIVEFS="${REPACK_LIVEFS:-0}"
STRIP_PROFILE="${STRIP_PROFILE:-none}"
INSTALL_RUNTIME="${INSTALL_RUNTIME:-0}"
VOLUME_ID="${VOLUME_ID:-TEMPLE4}"
OWNER_UID="${SUDO_UID:-$(id -u)}"
OWNER_GID="${SUDO_GID:-$(id -g)}"

require_wsl_environment "Temple4 ISO build"

if [ "$STRIP_PROFILE" != "none" ] || [ "$INSTALL_RUNTIME" = "1" ]; then
    REPACK_LIVEFS=1
fi

if { [ "$REPACK_LIVEFS" = "1" ] || [ "$STRIP_PROFILE" != "none" ] || [ "$INSTALL_RUNTIME" = "1" ]; } && [ "$(id -u)" -ne 0 ]; then
    require_command_hint sudo sudo
    exec sudo env \
        SOURCE_DIR="$SOURCE_DIR" \
        CIA_DIR="$CIA_DIR" \
        WORK_DIR="$WORK_DIR" \
        ISO_ROOT="$ISO_ROOT" \
        LIVE_ROOT="$LIVE_ROOT" \
        OUTPUT_ISO="$OUTPUT_ISO" \
        REPACK_LIVEFS="$REPACK_LIVEFS" \
        STRIP_PROFILE="$STRIP_PROFILE" \
        INSTALL_RUNTIME="$INSTALL_RUNTIME" \
        VOLUME_ID="$VOLUME_ID" \
        bash "$0" "$@"
fi

require_command() {
    require_command_hint "$1" "$1"
}

require_path() {
    if [ ! -e "$1" ]; then
        echo "ERROR: required path is missing: $1" >&2
        exit 1
    fi
}

resolve_isohybrid_mbr() {
    if [ -n "$ISOHYBRID_MBR" ]; then
        require_path "$ISOHYBRID_MBR"
        return
    fi

    local candidate
    for candidate in \
        /usr/lib/ISOLINUX/isohdpfx.bin \
        /usr/lib/syslinux/isohdpfx.bin \
        /usr/share/syslinux/isohdpfx.bin
    do
        if [ -f "$candidate" ]; then
            ISOHYBRID_MBR="$candidate"
            return
        fi
    done

    echo "ERROR: Syslinux isohybrid MBR blob was not found." >&2
    echo "Install it with your distro's syslinux package, or set ISOHYBRID_MBR=/path/to/isohdpfx.bin." >&2
    exit 1
}

copy_tree() {
    local src="$1"
    local dst="$2"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude='[BOOT]' "$src"/ "$dst"/
    else
        rm -rf "$dst"
        mkdir -p "$dst"
        cp -a "$src"/. "$dst"/
        rm -rf "$dst/[BOOT]"
    fi
}

soft_rebrand_iso_root() {
    echo "Applying Temple4 boot-menu branding..."

    local boot_text_files=(
        "$ISO_ROOT/boot/grub/grub.cfg" \
        "$ISO_ROOT/boot/grub/x86_64-efi/grub.cfg" \
        "$ISO_ROOT/isolinux/live.cfg" \
        "$ISO_ROOT/isolinux/menu.cfg" \
        "$ISO_ROOT/isolinux/stdmenu.cfg"
    )
    if [ -d "$ISO_ROOT/isolinux" ]; then
        while IFS= read -r file; do
            boot_text_files+=("$file")
        done < <(find "$ISO_ROOT/isolinux" -maxdepth 1 -type f \( -name 'f*.txt' -o -name '*.txt' \))
    fi

    for file in "${boot_text_files[@]}"; do
        if [ -f "$file" ]; then
            sed -i \
                -e 's/Debian GNU\/Linux/Temple4/g' \
                -e 's/Debian Live/Temple4 Live/g' \
                -e 's/Debian)/Temple4)/g' \
                -e 's/debian\.org/temple4.local/g' \
                -e 's/locales=it_IT.UTF-8 keyboard-layouts=it/locales=en_US.UTF-8 keyboard-layouts=us/g' \
                -e 's/boot=live[[:space:]]*$/boot=live locales=en_US.UTF-8 keyboard-layouts=us /' \
                "$file"
        fi
    done

    if [ -f "$SCRIPT_DIR/Temple4.png" ]; then
        cp "$SCRIPT_DIR/Temple4.png" "$ISO_ROOT/boot/grub/splash.png"
        cp "$SCRIPT_DIR/Temple4.png" "$ISO_ROOT/isolinux/splash.png"
    fi

    if [ -d "$CIA_DIR" ]; then
        mkdir -p "$ISO_ROOT/Temple4"
        cp -a "$CIA_DIR"/. "$ISO_ROOT/Temple4"/
    fi

    mkdir -p "$ISO_ROOT/Temple4"
    for notice_file in LICENSE THIRD_PARTY_NOTICES.md; do
        if [ -f "$SCRIPT_DIR/$notice_file" ]; then
            cp "$SCRIPT_DIR/$notice_file" "$ISO_ROOT/Temple4/$notice_file"
        fi
    done
}

mounted_chroot_paths=()

mount_chroot_runtime() {
    local root="$1"

    mkdir -p "$root/dev" "$root/dev/pts" "$root/proc" "$root/sys" "$root/run"

    if ! mountpoint -q "$root/dev"; then
        mount --bind /dev "$root/dev"
        mounted_chroot_paths+=("$root/dev")
    fi

    if ! mountpoint -q "$root/dev/pts"; then
        mount -t devpts devpts "$root/dev/pts"
        mounted_chroot_paths+=("$root/dev/pts")
    fi

    if ! mountpoint -q "$root/proc"; then
        mount -t proc proc "$root/proc"
        mounted_chroot_paths+=("$root/proc")
    fi

    if ! mountpoint -q "$root/sys"; then
        mount --bind /sys "$root/sys"
        mounted_chroot_paths+=("$root/sys")
    fi

    if ! mountpoint -q "$root/run"; then
        mount --bind /run "$root/run"
        mounted_chroot_paths+=("$root/run")
    fi

    cp /etc/resolv.conf "$root/etc/resolv.conf"
}

unmount_chroot_runtime() {
    local mountpoint_path
    for ((idx=${#mounted_chroot_paths[@]}-1; idx>=0; idx--)); do
        mountpoint_path="${mounted_chroot_paths[$idx]}"
        if mountpoint -q "$mountpoint_path"; then
            umount "$mountpoint_path"
        fi
    done
    mounted_chroot_paths=()
}

write_livefs_launchers() {
    local root="$1"

    mkdir -p \
        "$root/etc/skel/Terry" \
        "$root/etc/skel/Desktop" \
        "$root/usr/local/bin" \
        "$root/usr/share/applications"

    mkdir -p "$root/usr/share/doc/temple4"
    for notice_file in LICENSE THIRD_PARTY_NOTICES.md; do
        if [ -f "$SCRIPT_DIR/$notice_file" ]; then
            cp "$SCRIPT_DIR/$notice_file" "$root/usr/share/doc/temple4/$notice_file"
        fi
    done

    if [ -d "$CIA_DIR" ]; then
        cp -a "$CIA_DIR"/. "$root/etc/skel/Terry"/
    fi

    cat > "$root/usr/local/bin/temple4-run-templeos" <<'EOF'
#!/bin/sh
set -eu

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    zenity --error --text='QEMU is not installed in this live image.' 2>/dev/null || printf '%s\n' 'QEMU is not installed in this live image.' >&2
    exit 1
fi

for iso in "$HOME/Terry/TempleOS.ISO" "/run/live/medium/Temple4/TempleOS.ISO"; do
    if [ -f "$iso" ]; then
        exec qemu-system-x86_64 -m 512 -cdrom "$iso" -boot d -display gtk,gl=off -name TempleOS
    fi
done

printf '%s\n' 'TempleOS.ISO was not found in ~/Terry or /run/live/medium/Temple4.' >&2
exit 1
EOF

    cat > "$root/usr/local/bin/temple4-run-zealos" <<'EOF'
#!/bin/sh
set -eu

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    zenity --error --text='QEMU is not installed in this live image.' 2>/dev/null || printf '%s\n' 'QEMU is not installed in this live image.' >&2
    exit 1
fi

for iso in "$HOME/Terry/ZealOS-BSD2-UEFI-2025-11-10-02_56_42.iso" "/run/live/medium/Temple4/ZealOS-BSD2-UEFI-2025-11-10-02_56_42.iso"; do
    if [ -f "$iso" ]; then
        exec qemu-system-x86_64 \
            -m 1024 \
            -device ich9-ahci,id=ahci \
            -drive "if=none,id=zealcd,media=cdrom,readonly=on,file=$iso" \
            -device ide-cd,bus=ahci.0,drive=zealcd \
            -boot d \
            -display gtk,gl=off \
            -name ZealOS
    fi
done

printf '%s\n' 'ZealOS ISO was not found in ~/Terry or /run/live/medium/Temple4.' >&2
exit 1
EOF

    chmod +x "$root/usr/local/bin/temple4-run-templeos" "$root/usr/local/bin/temple4-run-zealos"

    cat > "$root/usr/local/bin/temple4-run-exodus" <<'EOF'
#!/bin/sh
set -eu

if command -v exodus >/dev/null 2>&1; then
    exec exodus -f /usr/share/exodus/HCRT.BIN -t /T/
fi

zenity --error --text='Exodus is not installed in this live image.' 2>/dev/null || printf '%s\n' 'Exodus is not installed in this live image.' >&2
exit 1
EOF

    chmod +x "$root/usr/local/bin/temple4-run-exodus"

    cat > "$root/usr/share/applications/temple4-templeos.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=TempleOS
Comment=Boot TempleOS in QEMU
Exec=temple4-run-templeos
Terminal=false
Categories=System;Emulator;
StartupNotify=false
X-XFCE-Trusted=true
EOF

    cat > "$root/usr/share/applications/temple4-zealos.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZealOS
Comment=Boot ZealOS in QEMU
Exec=temple4-run-zealos
Terminal=false
Categories=System;Emulator;
StartupNotify=false
X-XFCE-Trusted=true
EOF

    cat > "$root/usr/share/applications/temple4-exodus.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Exodus
Comment=Launch the Exodus TempleOS appliance
Exec=temple4-run-exodus
Terminal=false
Categories=System;Emulator;
StartupNotify=false
X-XFCE-Trusted=true
EOF

    cp "$root/usr/share/applications/temple4-templeos.desktop" "$root/etc/skel/Desktop/TempleOS.desktop"
    cp "$root/usr/share/applications/temple4-zealos.desktop" "$root/etc/skel/Desktop/ZealOS.desktop"
    cp "$root/usr/share/applications/temple4-exodus.desktop" "$root/etc/skel/Desktop/Exodus.desktop"
    chmod +x "$root/etc/skel/Desktop/TempleOS.desktop" "$root/etc/skel/Desktop/ZealOS.desktop" "$root/etc/skel/Desktop/Exodus.desktop"
    rm -f "$root/etc/skel/Desktop/calamares-install-debian.desktop" "$root/etc/skel/Desktop/"*calamares*.desktop
    rm -f "$root/etc/xdg/autostart/calamares-desktop-icon.desktop"

    if [ -d "$root/home/user" ]; then
        mkdir -p "$root/home/user/Desktop" "$root/home/user/Terry"
        rm -f "$root/home/user/Desktop/calamares-install-debian.desktop" "$root/home/user/Desktop/"*calamares*.desktop
        cp "$root/usr/share/applications/temple4-templeos.desktop" "$root/home/user/Desktop/TempleOS.desktop"
        cp "$root/usr/share/applications/temple4-zealos.desktop" "$root/home/user/Desktop/ZealOS.desktop"
        cp "$root/usr/share/applications/temple4-exodus.desktop" "$root/home/user/Desktop/Exodus.desktop"
        chmod +x "$root/home/user/Desktop/TempleOS.desktop" "$root/home/user/Desktop/ZealOS.desktop" "$root/home/user/Desktop/Exodus.desktop"
        if [ -d "$CIA_DIR" ]; then
            cp -a "$CIA_DIR"/. "$root/home/user/Terry"/
        fi
        chown -R 1000:1000 "$root/home/user/Desktop" "$root/home/user/Terry" 2>/dev/null || true
    fi

    cat > "$root/usr/local/bin/temple4-trust-desktop-launchers" <<'EOF'
#!/bin/sh
set -eu

for launcher in "$HOME/Desktop/TempleOS.desktop" "$HOME/Desktop/ZealOS.desktop" "$HOME/Desktop/Exodus.desktop" "$HOME/Desktop/HolyC Demo.desktop" "$HOME/Desktop/Install Temple4.desktop"; do
    [ -f "$launcher" ] || continue
    chmod +x "$launcher" 2>/dev/null || true
    if command -v gio >/dev/null 2>&1; then
        gio set "$launcher" metadata::trusted true 2>/dev/null || true
        gio set -t string "$launcher" metadata::xfce-exe-checksum "$(sha256sum "$launcher" | awk '{print $1}')" 2>/dev/null || true
        touch "$launcher" 2>/dev/null || true
    fi
done
EOF
    chmod +x "$root/usr/local/bin/temple4-trust-desktop-launchers"

    mkdir -p "$root/etc/xdg/autostart"
    cat > "$root/etc/xdg/autostart/temple4-trust-desktop-launchers.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Trust Temple4 Desktop Launchers
Exec=temple4-trust-desktop-launchers
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
}

write_default_wallpaper() {
    local root="$1"
    local wallpaper="/usr/share/backgrounds/temple4/Temple4.png"
    local xfce_wallpaper="/usr/share/backgrounds/xfce/Temple4.png"
    local xfce_backdrop="/usr/share/xfce4/backdrops/Temple4.png"

    rm -rf \
        "$root/usr/share/wallpapers" \
        "$root/usr/share/images/desktop-base"

    if [ -d "$root/usr/share/backgrounds" ]; then
        find "$root/usr/share/backgrounds" -mindepth 1 -maxdepth 1 \
            ! -name temple4 \
            -exec rm -rf {} +
    fi

    mkdir -p "$root/usr/share/backgrounds/temple4"
    cp "$SCRIPT_DIR/Temple4.png" "$root$wallpaper"
    chmod 644 "$root$wallpaper"

    mkdir -p "$root/usr/share/backgrounds/xfce"
    ln -sf ../temple4/Temple4.png "$root$xfce_wallpaper"

    mkdir -p "$root/usr/share/xfce4/backdrops"
    ln -sf ../../backgrounds/temple4/Temple4.png "$root$xfce_backdrop"

    for profile in "$root/etc/skel" "$root/home/user"; do
        mkdir -p "$profile/.config/xfce4/xfconf/xfce-perchannel-xml"
        cat > "$profile/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper"/>
        </property>
      </property>
      <property name="monitor1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper"/>
        </property>
      </property>
      <property name="monitorVirtual1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper"/>
        </property>
      </property>
      <property name="monitorVirtual-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
    done

    chown -R 1000:1000 "$root/home/user/.config" 2>/dev/null || true

    mkdir -p "$root/usr/local/bin"
    cat > "$root/usr/local/bin/temple4-apply-wallpaper" <<'EOF'
#!/bin/sh
set -eu

wallpaper="/usr/share/backgrounds/temple4/Temple4.png"
[ -r "$wallpaper" ] || exit 0
command -v xfconf-query >/dev/null 2>&1 || exit 0

apply_base() {
    base="$1"
    xfconf-query -c xfce4-desktop -p "$base/color-style" -n -t int -s 0 2>/dev/null || true
    xfconf-query -c xfce4-desktop -p "$base/image-style" -n -t int -s 5 2>/dev/null || true
    xfconf-query -c xfce4-desktop -p "$base/last-image" -n -t string -s "$wallpaper" 2>/dev/null || true
    xfconf-query -c xfce4-desktop -p "$base/last-single-image" -n -t string -s "$wallpaper" 2>/dev/null || true
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
    xfconf-query -c xfce4-desktop -l 2>/dev/null |
        awk '
            /\/backdrop\/screen[^/]+\/monitor[^/]+\/workspace[^/]+\// {
                sub(/\/[^/]+$/, "")
                print
            }
        '

    for monitor in monitor0 monitor1 monitorVirtual1 monitorVirtual-1; do
        printf '/backdrop/screen0/%s/workspace0\n' "$monitor"
    done

    if command -v xrandr >/dev/null 2>&1; then
        xrandr --query 2>/dev/null |
            awk '/ connected/ { print "/backdrop/screen0/monitor" $1 "/workspace0" }'
    fi
} | sort -u > "$tmp"

while IFS= read -r base; do
    [ -n "$base" ] && apply_base "$base"
done < "$tmp"

xfdesktop --reload >/dev/null 2>&1 || true
EOF
    chmod +x "$root/usr/local/bin/temple4-apply-wallpaper"

    mkdir -p "$root/etc/xdg/autostart"
    cat > "$root/etc/xdg/autostart/temple4-apply-wallpaper.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Apply Temple4 Wallpaper
Exec=sh -c "sleep 2; temple4-apply-wallpaper; sleep 5; temple4-apply-wallpaper"
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
EOF

    if [ -f "$root/etc/lightdm/lightdm-gtk-greeter.conf" ]; then
        if grep -q '^background=' "$root/etc/lightdm/lightdm-gtk-greeter.conf"; then
            sed -i "s|^background=.*|background=$wallpaper|" "$root/etc/lightdm/lightdm-gtk-greeter.conf"
        else
            printf '\nbackground=%s\n' "$wallpaper" >> "$root/etc/lightdm/lightdm-gtk-greeter.conf"
        fi
    fi
}

configure_calamares() {
    local root="$1"
    local settings="$root/etc/calamares/settings.conf"

    if [ -f "$settings" ]; then
        # Ventoy/live-boot can keep the install medium busy until shutdown.
        # Let the installed target complete instead of failing on that cleanup.
        sed -i '/^[[:space:]]*-[[:space:]]*sources-media-unmount[[:space:]]*$/d' "$settings"
    fi

    if [ -f "$root/etc/calamares/modules/finished.conf" ]; then
        sed -i \
            -e 's/^restartNowChecked:.*/restartNowChecked: false/' \
            -e 's|^restartNowCommand:.*|restartNowCommand: "systemctl reboot"|' \
            "$root/etc/calamares/modules/finished.conf"
    fi

    mkdir -p \
        "$root/usr/local/bin" \
        "$root/usr/share/applications" \
        "$root/etc/skel/Desktop" \
        "$root/home/user/Desktop"

    cat > "$root/usr/local/bin/temple4-install" <<'EOF'
#!/bin/sh
set -eu

restore_fstab() {
    if [ -e /etc/fstab.orig.temple4-calamares ]; then
        sudo mv /etc/fstab.orig.temple4-calamares /etc/fstab 2>/dev/null || true
    fi
}

trap restore_fstab EXIT INT TERM

if [ -e /etc/fstab ] && [ ! -e /etc/fstab.orig.temple4-calamares ]; then
    sudo mv /etc/fstab /etc/fstab.orig.temple4-calamares 2>/dev/null || true
fi

export QT_AUTO_SCREEN_SCALE_FACTOR=1

if command -v xhost >/dev/null 2>&1; then
    xhost +si:localuser:root >/dev/null 2>&1 || true
fi

set +e
pkexec calamares
status=$?
set -e

if command -v xhost >/dev/null 2>&1; then
    xhost -si:localuser:root >/dev/null 2>&1 || true
fi

exit "$status"
EOF
    chmod +x "$root/usr/local/bin/temple4-install"

    cat > "$root/usr/bin/calamares-install-debian" <<'EOF'
#!/bin/sh
exec temple4-install "$@"
EOF
    chmod +x "$root/usr/bin/calamares-install-debian"

    cat > "$root/usr/share/applications/temple4-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Temple4
Comment=Install the Temple4 live system to disk
Exec=temple4-install
Icon=install-debian
Terminal=false
Categories=System;
StartupNotify=true
X-XFCE-Trusted=true
EOF

    cp "$root/usr/share/applications/temple4-install.desktop" "$root/etc/skel/Desktop/Install Temple4.desktop"
    cp "$root/usr/share/applications/temple4-install.desktop" "$root/home/user/Desktop/Install Temple4.desktop"
    chmod +x "$root/etc/skel/Desktop/Install Temple4.desktop" "$root/home/user/Desktop/Install Temple4.desktop"

    find "$root/etc/skel/Desktop" "$root/home/user/Desktop" -maxdepth 1 -type f -iname '*calamares*.desktop' -delete 2>/dev/null || true
    rm -f "$root/etc/xdg/autostart/calamares-desktop-icon.desktop"

    rm -f "$root/usr/share/applications/calamares-install-debian.desktop"

    chown 1000:1000 "$root/home/user/Desktop/Install Temple4.desktop" 2>/dev/null || true
}

configure_system_identity() {
    local root="$1"

    printf 'temple4\n' > "$root/etc/hostname"
    cat > "$root/etc/issue" <<'EOF'
Temple4 \n \l
EOF
    cat > "$root/etc/issue.net" <<'EOF'
Temple4
EOF

    cat > "$root/usr/lib/os-release" <<'EOF'
PRETTY_NAME="Temple4"
NAME="Temple4"
VERSION_ID="4"
VERSION="4"
VERSION_CODENAME=trixie
ID=temple4
ID_LIKE=debian
HOME_URL="https://temple4.local/"
SUPPORT_URL="https://temple4.local/"
BUG_REPORT_URL="https://temple4.local/"
EOF

    ln -sf ../usr/lib/os-release "$root/etc/os-release"

    cat > "$root/etc/lsb-release" <<'EOF'
DISTRIB_ID=Temple4
DISTRIB_RELEASE=4
DISTRIB_CODENAME=trixie
DISTRIB_DESCRIPTION="Temple4"
EOF

    printf '4\n' > "$root/etc/temple4_version"
}

strip_lite_profile() {
    local root="$1"
    local purge_packages=(
        audacious
        audacious-plugins
        audacious-plugins-data
        anthy
        anthy-common
        bluetooth
        bluez
        cups
        cups-client
        cups-common
        cups-core-drivers
        cups-daemon
        cups-filters
        cups-filters-core-drivers
        cups-ipp-utils
        cups-ppdc
        cups-server-common
        firefox-esr
        fonts-ipafont-mincho
        fonts-vlgothic
        fonts-wqy-microhei
        geany
        geany-common
        geany-plugin-spellcheck
        geany-plugins-common
        gnome-sound-recorder
        gnumeric
        gnumeric-common
        kasumi
        lazpaint-qt5
        linux-image-6.12.67-gnu
        live-clone
        man-db
        printer-driver-cups-pdf
        refractasnapshot-base
        refractasnapshot-gui
        ristretto
        sylpheed
        sylpheed-i18n
        vlc
        vlc-bin
        vlc-data
        vlc-l10n
        vlc-plugin-base
        vlc-plugin-qt
        vlc-plugin-video-output
    )

    echo "Applying lite strip profile..."
    mount_chroot_runtime "$root"
    trap 'unmount_chroot_runtime; trap - RETURN' RETURN

    local installed_purge_packages=()
    local package_name
    for package_name in "${purge_packages[@]}"; do
        if chroot "$root" dpkg-query -W -f='${db:Status-Abbrev}' "$package_name" 2>/dev/null | grep -q '^i'; then
            installed_purge_packages+=("$package_name")
        fi
    done

    if [ "${#installed_purge_packages[@]}" -gt 0 ]; then
        chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get -y purge "${installed_purge_packages[@]}" >/dev/null
    else
        echo "Lite strip profile: no matching installed packages to purge."
    fi

    chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge >/dev/null
    chroot "$root" apt-get clean >/dev/null

    rm -rf \
        "$root/var/cache/apt/archives"/* \
        "$root/var/lib/apt/lists"/* \
        "$root/var/cache/man"/* \
        "$root/var/log/apt"/* \
        "$root/tmp"/* \
        "$root/var/tmp"/*
    rm -f "$root/var/log/alternatives.log" "$root/var/log/dpkg.log"

    # Keep English and C locale support; remove the large multilingual payload.
    find "$root/usr/share/locale" -mindepth 1 -maxdepth 1 \
        ! -name 'C' \
        ! -name 'C.*' \
        ! -name 'en' \
        ! -name 'en_*' \
        ! -name 'locale.alias' \
        -exec rm -rf {} +

    rm -rf \
        "$root/usr/share/man" \
        "$root/usr/share/info" \
        "$root/usr/share/help" \
        "$root/usr/share/lintian"

    if [ -d "$root/usr/share/doc" ]; then
        find "$root/usr/share/doc" -mindepth 2 -type f ! -name copyright -delete
        find "$root/usr/share/doc" -mindepth 2 -type l ! -name copyright -delete
        find "$root/usr/share/doc" -type d -empty -delete
    fi

    mkdir -p "$root/usr/share/doc/temple4"
    for notice_file in LICENSE THIRD_PARTY_NOTICES.md; do
        if [ -f "$SCRIPT_DIR/$notice_file" ]; then
            cp "$SCRIPT_DIR/$notice_file" "$root/usr/share/doc/temple4/$notice_file"
        fi
    done

    rm -f \
        "$root/etc/apparmor.d/firefox" \
        "$root/usr/share/xfce4/helpers/firefox.desktop"
    find "$root/var/cache/apparmor" -mindepth 1 -maxdepth 1 -type f -iname '*firefox*' -delete 2>/dev/null || true

    rm -rf \
        "$root/usr/share/wallpapers" \
        "$root/usr/share/images/desktop-base"

    rm -rf \
        "$root/boot/"*6.12.67-gnu* \
        "$root/usr/lib/modules/6.12.67-gnu" \
        "$root/usr/lib/modules/6.12.48+deb13-amd64"
    rm -f "$root/vmlinuz.old" "$root/initrd.img.old"

    if [ -d "$root/usr/share/backgrounds" ]; then
        find "$root/usr/share/backgrounds" -mindepth 1 -maxdepth 1 \
            ! -name temple4 \
            -exec rm -rf {} +
    fi

    mkdir -p "$root/usr/share/backgrounds/xfce"
    ln -sf ../temple4/Temple4.png "$root/usr/share/backgrounds/xfce/Temple4.png"

    mkdir -p "$root/usr/share/xfce4/backdrops"
    if [ -f "$root/usr/share/backgrounds/temple4/Temple4.png" ]; then
        ln -sf ../../backgrounds/temple4/Temple4.png "$root/usr/share/xfce4/backdrops/Temple4.png"
    fi

    unmount_chroot_runtime
    trap - RETURN
}

configure_english_locale() {
    local root="$1"

    cat > "$root/etc/default/locale" <<'EOF'
LANG=en_US.UTF-8
LANGUAGE=en_US:en
LC_ALL=en_US.UTF-8
EOF

    cat > "$root/etc/locale.conf" <<'EOF'
LANG=en_US.UTF-8
LANGUAGE=en_US:en
LC_ALL=en_US.UTF-8
EOF

    sed -i 's/^[# ]*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$root/etc/locale.gen"
    sed -i 's/^[^#].*it_IT/# &/' "$root/etc/locale.gen"

    cat > "$root/etc/profile.d/temple4-locale.sh" <<'EOF'
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
EOF

    mkdir -p "$root/etc/skel" "$root/home/user"
    cat > "$root/etc/skel/.xsessionrc" <<'EOF'
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
EOF
    cp "$root/etc/skel/.xsessionrc" "$root/home/user/.xsessionrc"
    chown 1000:1000 "$root/home/user/.xsessionrc" 2>/dev/null || true
}

configure_default_browser() {
    local root="$1"

    mkdir -p "$root/etc/xdg/xfce4" "$root/etc/skel/.config" "$root/home/user/.config"

    if [ -f "$root/etc/xdg/xfce4/helpers.rc" ]; then
        sed -i 's/^WebBrowser=.*/WebBrowser=netsurf-gtk/' "$root/etc/xdg/xfce4/helpers.rc"
        sed -i 's/^TerminalEmulator=.*/TerminalEmulator=temple4-terminal/' "$root/etc/xdg/xfce4/helpers.rc"
        grep -q '^WebBrowser=' "$root/etc/xdg/xfce4/helpers.rc" || printf '%s\n' 'WebBrowser=netsurf-gtk' >> "$root/etc/xdg/xfce4/helpers.rc"
        grep -q '^TerminalEmulator=' "$root/etc/xdg/xfce4/helpers.rc" || printf '%s\n' 'TerminalEmulator=temple4-terminal' >> "$root/etc/xdg/xfce4/helpers.rc"
    else
        cat > "$root/etc/xdg/xfce4/helpers.rc" <<'EOF'
WebBrowser=netsurf-gtk
MailReader=thunderbird
TerminalEmulator=temple4-terminal
FileManager=thunar
EOF
    fi

    cat > "$root/usr/share/applications/xfce4-web-browser.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Web Browser
Comment=Browse the web
Exec=netsurf-gtk %u
Icon=netsurf
StartupNotify=true
Terminal=false
Categories=Network;WebBrowser;X-XFCE;X-Xfce-Toplevel;
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;application/xhtml+xml;
OnlyShowIn=XFCE;
X-XFCE-MimeType=x-scheme-handler/http;x-scheme-handler/https;
X-AppStream-Ignore=True
EOF

    cat > "$root/etc/xdg/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/http=netsurf-gtk.desktop
x-scheme-handler/https=netsurf-gtk.desktop
text/html=netsurf-gtk.desktop
application/xhtml+xml=netsurf-gtk.desktop
application/xml=netsurf-gtk.desktop
text/xml=netsurf-gtk.desktop
EOF

    cp "$root/etc/xdg/mimeapps.list" "$root/etc/skel/.config/mimeapps.list"
    cp "$root/etc/xdg/mimeapps.list" "$root/home/user/.config/mimeapps.list"
    chown 1000:1000 "$root/home/user/.config/mimeapps.list" 2>/dev/null || true

    chroot "$root" update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/netsurf-gtk 80 >/dev/null 2>&1 || true
    chroot "$root" update-alternatives --set x-www-browser /usr/bin/netsurf-gtk >/dev/null 2>&1 || true
    chroot "$root" update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/netsurf-gtk 80 >/dev/null 2>&1 || true
    chroot "$root" update-alternatives --set gnome-www-browser /usr/bin/netsurf-gtk >/dev/null 2>&1 || true
}

install_ratty_terminal() {
    local root="$1"
    local ratty_archive="$CIA_DIR/ratty-x86_64-unknown-linux-gnu.tar.xz"

    if [ ! -f "$ratty_archive" ]; then
        echo "ERROR: Ratty terminal archive was not found at $ratty_archive." >&2
        exit 1
    fi

    require_command_hint tar tar

    echo "Installing Ratty terminal as the Temple4 default terminal..."

    mkdir -p \
        "$root/opt/ratty" \
        "$root/usr/local/bin" \
        "$root/usr/share/applications" \
        "$root/usr/share/xfce4/helpers"

    rm -rf "$root/opt/ratty"/*
    tar -xJf "$ratty_archive" -C "$root/opt/ratty" --strip-components=1
    chmod 755 "$root/opt/ratty/ratty"
    ln -sf /opt/ratty/ratty "$root/usr/local/bin/ratty"

    cat > "$root/usr/local/bin/temple4-terminal" <<'EOF'
#!/bin/sh
set -u

hold=0
if [ "${1:-}" = "--hold" ]; then
    hold=1
    shift
fi

case "${1:-}" in
    -e|--execute|--command|-x)
        shift
        if [ "$#" -eq 0 ]; then
            printf '%s\n' 'temple4-terminal: missing command after -e.' >&2
            exit 2
        fi
        if command -v xfce4-terminal >/dev/null 2>&1; then
            if [ "$hold" -eq 1 ]; then
                exec xfce4-terminal --hold -x "$@"
            fi
            exec xfce4-terminal -x "$@"
        fi
        exec "$@"
        ;;
esac

if command -v ratty >/dev/null 2>&1; then
    started_at="$(date +%s 2>/dev/null || printf 0)"
    ratty "$@"
    status="$?"
    finished_at="$(date +%s 2>/dev/null || printf 0)"
    elapsed=$((finished_at - started_at))

    if [ "$status" -eq 0 ]; then
        if [ "$elapsed" -le 2 ]; then
            message="Ratty exited immediately with status 0. This usually means the terminal process started but could not keep a usable graphical session. In a virtual machine, enable 3D acceleration/Vulkan if available, try a different display mode, or run xfce4-terminal manually."
            if command -v zenity >/dev/null 2>&1; then
                zenity --warning --title='Ratty Terminal exited' --text="$message" 2>/dev/null || true
            fi
            printf '%s\n' "$message" >&2
        fi
        exit 0
    fi

    message="Ratty failed with status $status. Temple4 kept XFCE installed for command launchers, but the default interactive terminal is Ratty. Check the live graphics stack, Vulkan/Mesa support, or run xfce4-terminal manually."
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title='Ratty Terminal failed' --text="$message" 2>/dev/null || true
    fi
    printf '%s\n' "$message" >&2
    exit "$status"
fi

printf '%s\n' 'No graphical terminal emulator is installed.' >&2
exit 1
EOF
    chmod +x "$root/usr/local/bin/temple4-terminal"

    cat > "$root/usr/share/applications/ratty.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Ratty Terminal
Comment=TempleOS-inspired GPU terminal
Exec=temple4-terminal
Icon=utilities-terminal
StartupNotify=true
Terminal=false
Categories=System;TerminalEmulator;
Keywords=shell;prompt;command;commandline;cmd;terminal;
EOF

    cat > "$root/usr/share/xfce4/helpers/ratty.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=X-XFCE-Helper
Name=Ratty Terminal
StartupNotify=true
X-XFCE-Binaries=temple4-terminal;ratty;
X-XFCE-Category=TerminalEmulator
X-XFCE-Commands=temple4-terminal
X-XFCE-CommandsWithParameter=temple4-terminal "%s"
EOF

    cat > "$root/usr/share/xfce4/helpers/temple4-terminal.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=X-XFCE-Helper
Name=Temple4 Terminal
StartupNotify=true
X-XFCE-Binaries=temple4-terminal;ratty;xfce4-terminal;
X-XFCE-Category=TerminalEmulator
X-XFCE-Commands=temple4-terminal
X-XFCE-CommandsWithParameter=temple4-terminal -e "%s"
EOF

    ln -sf /usr/local/bin/temple4-terminal "$root/usr/local/bin/x-terminal-emulator"
    chroot "$root" update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/local/bin/temple4-terminal 90 >/dev/null 2>&1 || true
    chroot "$root" update-alternatives --set x-terminal-emulator /usr/local/bin/temple4-terminal >/dev/null 2>&1 || true
}

install_holyc_tools() {
    local root="$1"
    local holyc_src="$SCRIPT_DIR/third_party/HolyC-for-Linux"

    if [ ! -d "$holyc_src" ]; then
        echo "ERROR: HolyC-for-Linux source was not found at $holyc_src." >&2
        exit 1
    fi

    echo "Installing HolyC-for-Linux tooling..."

    mkdir -p \
        "$root/opt/holyc-for-linux" \
        "$root/usr/local/bin" \
        "$root/usr/share/applications" \
        "$root/usr/share/doc/temple4/examples"

    rm -rf "$root/opt/holyc-for-linux"/*
    cp -a "$holyc_src"/. "$root/opt/holyc-for-linux"/

    cat > "$root/usr/local/bin/holyc" <<'EOF'
#!/bin/sh
set -eu

toolroot="/opt/holyc-for-linux"

usage() {
    cat <<'USAGE'
Usage:
  holyc <file.hc>
  holyc translate <file.hc>
  holyc dump-ast <file.c>
  holyc --help

Examples:
  cp /usr/share/temple4/examples/hello.hc .
  holyc hello.hc
USAGE
}

if [ "$#" -eq 0 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ "${1:-}" != "translate" ] && [ "${1:-}" != "dump-ast" ]; then
    case "${1:-}" in
        *.hc) set -- translate "$1" ;;
        *) usage >&2; exit 2 ;;
    esac
fi

command="$1"
target="${2:-}"

if [ -z "$target" ]; then
    usage >&2
    exit 2
fi

case "$target" in
    /*) target_path="$target" ;;
    *) target_path="$PWD/$target" ;;
esac

cd "$toolroot"
PYTHONPATH="$toolroot${PYTHONPATH:+:$PYTHONPATH}" exec python3 -c 'from secularize import main; main()' "$command" "$target_path"
EOF
    chmod +x "$root/usr/local/bin/holyc"

    cat > "$root/usr/local/bin/holyc-demo" <<'EOF'
#!/bin/sh
set -eu

demo_dir="${HOME:-/tmp}/HolyC"
mkdir -p "$demo_dir"
cp /usr/share/temple4/examples/hello.hc "$demo_dir/hello.hc"
cd "$demo_dir"

holyc hello.hc

printf '%s\n' "Wrote $demo_dir/hello.c"
printf '%s\n' ''
sed -n '1,120p' "$demo_dir/hello.c"
printf '%s\n' ''
printf '%s\n' 'Type exit or close this window when you are done.'
exec "${SHELL:-/bin/sh}"
EOF
    chmod +x "$root/usr/local/bin/holyc-demo"

    mkdir -p "$root/usr/share/temple4/examples"
    cat > "$root/usr/share/temple4/examples/hello.hc" <<'EOF'
Print("Hello from HolyC on Temple4\n");
I64 answer = 42;
Print("Answer: %d\n", answer);
EOF

    cat > "$root/usr/share/applications/temple4-holyc-demo.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=HolyC Demo
Comment=Translate a small HolyC example
Exec=temple4-terminal -e holyc-demo
Terminal=false
Categories=Development;
StartupNotify=false
EOF

    mkdir -p "$root/etc/skel/Desktop"
    cp "$root/usr/share/applications/temple4-holyc-demo.desktop" "$root/etc/skel/Desktop/HolyC Demo.desktop"
    chmod +x "$root/etc/skel/Desktop/HolyC Demo.desktop"

    if [ -d "$root/home/user" ]; then
        mkdir -p "$root/home/user/Desktop"
        cp "$root/usr/share/applications/temple4-holyc-demo.desktop" "$root/home/user/Desktop/HolyC Demo.desktop"
        chmod +x "$root/home/user/Desktop/HolyC Demo.desktop"
        chown 1000:1000 "$root/home/user/Desktop/HolyC Demo.desktop" 2>/dev/null || true
    fi
}

install_templeos_theme_assets() {
    local root="$1"
    local theme_src="$SCRIPT_DIR/third_party/TempleOS-Theme"

    if [ ! -d "$theme_src" ]; then
        echo "ERROR: TempleOS-Theme assets were not found at $theme_src." >&2
        exit 1
    fi

    echo "Installing TempleOS icon, cursor, and font assets..."

    mkdir -p \
        "$root/usr/share/icons" \
        "$root/usr/share/fonts/truetype/templeos" \
        "$root/usr/share/temple4/third-party/TempleOS-Theme"

    rm -rf "$root/usr/share/icons/TempleOS" "$root/usr/share/icons/TempleOS_Cursor"
    cp -a "$theme_src/icons/TempleOS" "$root/usr/share/icons/TempleOS"
    cp -a "$theme_src/icons/TempleOS_Cursor" "$root/usr/share/icons/TempleOS_Cursor"
    cp "$theme_src/templeos_font.ttf" "$root/usr/share/fonts/truetype/templeos/templeos_font.ttf"
    cp "$theme_src/LICENSE" "$theme_src/README.md" "$root/usr/share/temple4/third-party/TempleOS-Theme/"

    mkdir -p "$root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
    if [ -f "$root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" ]; then
        sed -i \
            -e 's/value="Sans 10"/value="TempleOS 10"/' \
            -e 's/value="Monospace 10"/value="TempleOS 10"/' \
            -e 's/value="Tango"/value="TempleOS"/' \
            "$root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
        sed -i \
            -e '/CursorThemeName/s/value="[^"]*"/value="TempleOS_Cursor"/' \
            -e '/CursorThemeSize/s/value="[^"]*"/value="24"/' \
            "$root/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
    fi

    local profile
    for profile in "$root/etc/skel" "$root/home/user"; do
        [ -d "$profile" ] || continue

        mkdir -p \
            "$profile/.config/xfce4/xfconf/xfce-perchannel-xml" \
            "$profile/.config/gtk-3.0" \
            "$profile/.config/xfce4/terminal"

        cat > "$profile/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita"/>
    <property name="IconThemeName" type="string" value="TempleOS"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="TempleOS 10"/>
    <property name="MonospaceFontName" type="string" value="TempleOS 10"/>
    <property name="CursorThemeName" type="string" value="TempleOS_Cursor"/>
    <property name="CursorThemeSize" type="int" value="24"/>
  </property>
</channel>
EOF

        cat > "$profile/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Adwaita
gtk-icon-theme-name=TempleOS
gtk-cursor-theme-name=TempleOS_Cursor
gtk-cursor-theme-size=24
gtk-font-name=TempleOS 10
gtk-monospace-font-name=TempleOS 10
EOF

        cat > "$profile/.gtkrc-2.0" <<'EOF'
gtk-theme-name="Adwaita"
gtk-icon-theme-name="TempleOS"
gtk-cursor-theme-name="TempleOS_Cursor"
gtk-cursor-theme-size=24
gtk-font-name="TempleOS 10"
EOF

        cat > "$profile/.config/xfce4/terminal/terminalrc" <<'EOF'
[Configuration]
FontName=TempleOS 10
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscBordersDefault=TRUE
MiscCursorBlinks=FALSE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=80x24
MiscMenubarDefault=TRUE
MiscToolbarDefault=FALSE
MiscConfirmClose=TRUE
EOF
    done

    chown -R 1000:1000 "$root/home/user/.config" "$root/home/user/.gtkrc-2.0" 2>/dev/null || true
}

write_fetch_branding() {
    local root="$1"

    mkdir -p "$root/usr/share/temple4" "$root/usr/local/bin" "$root/etc/fastfetch"

    cat > "$root/usr/share/temple4/fetch-ascii.txt" <<'EOF'
TTTTTTTT  4444
   TT    44 44
   TT   44  44
   TT  44   44
   TT  44444444
   TT       44
   TT       44
EOF

    cat > "$root/etc/fastfetch/temple4.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/usr/share/temple4/fetch-ascii.txt",
    "color": {
      "1": "blue",
      "2": "white"
    }
  },
  "display": {
    "separator": "  "
  }
}
EOF

    cat > "$root/usr/local/bin/fastfetch" <<'EOF'
#!/bin/sh

temple4_fallback_fetch() {
    cat /usr/share/temple4/fetch-ascii.txt
    printf '\n'
    printf 'OS  %s\n' "$(awk -F= '/^PRETTY_NAME=/{ gsub(/"/, "", $2); print $2 }' /etc/os-release 2>/dev/null || printf Temple4)"
    printf 'Host  %s\n' "$(hostname 2>/dev/null || printf temple4)"
    printf 'Kernel  %s\n' "$(uname -sr 2>/dev/null)"
    printf 'Shell  %s\n' "${SHELL:-/bin/sh}"
    printf 'DE  %s\n' "${XDG_CURRENT_DESKTOP:-XFCE}"
}

if [ ! -x /usr/bin/fastfetch ]; then
    temple4_fallback_fetch
    exit 0
fi

/usr/bin/fastfetch --config /etc/fastfetch/temple4.jsonc "$@" || temple4_fallback_fetch
EOF

    rm -f "$root/usr/local/bin/neofetch"
    chmod +x "$root/usr/local/bin/fastfetch"
}

install_runtime_packages() {
    local root="$1"
    local exodus_deb="$root/tmp/exodus-appliance_1.0-2_amd64.deb"

    echo "Installing Temple4 runtime packages..."
    mount_chroot_runtime "$root"
    trap 'unmount_chroot_runtime; trap - RETURN' RETURN

    chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get update
    chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends qemu-system-x86 qemu-system-gui qemu-utils libsdl2-2.0-0 netsurf-gtk fontconfig libfontconfig1 libwayland-client0 libxkbcommon0 libegl1 libgl1 libvulkan1 mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 libx11-6 libx11-xcb1 libxcb1 libxcb-randr0 libxcb-xfixes0 libxkbcommon-x11-0 libxcursor1 libxi6 libxrandr2 python3 python3-docopt python3-pycparser
    chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends fastfetch ||
        echo "WARNING: fastfetch package was not available from the configured apt sources." >&2

    if [ -f "$CIA_DIR/exodus-appliance_1.0-2_amd64.deb" ]; then
        cp "$CIA_DIR/exodus-appliance_1.0-2_amd64.deb" "$exodus_deb"
        chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get -y install /tmp/exodus-appliance_1.0-2_amd64.deb
        rm -f "$exodus_deb"
    fi

    chroot "$root" locale-gen en_US.UTF-8
    configure_default_browser "$root"
    if command -v chroot >/dev/null 2>&1; then
        chroot "$root" fc-cache -f /usr/share/fonts >/dev/null 2>&1 || true
        chroot "$root" gtk-update-icon-cache -f -t /usr/share/icons/TempleOS >/dev/null 2>&1 || true
    fi
    chroot "$root" apt-get clean
    rm -rf "$root/var/cache/apt/archives"/* "$root/var/lib/apt/lists"/*

    unmount_chroot_runtime
    trap - RETURN
}

repack_livefs() {
    require_command_hint unsquashfs squashfs-tools
    require_command_hint mksquashfs squashfs-tools
    require_command_hint mount util-linux
    require_command_hint chroot coreutils

    echo "Repacking live filesystem with Temple4 userland additions..."
    rm -rf "$LIVE_ROOT"
    unsquashfs -d "$LIVE_ROOT" "$SOURCE_DIR/live/filesystem.squashfs" >/dev/null

    configure_system_identity "$LIVE_ROOT"
    sed -i 's|^user:x:1000:1000:.*:/home/user:/bin/bash$|user:x:1000:1000:Temple4 User,,,:/home/user:/bin/bash|' "$LIVE_ROOT/etc/passwd"

    install_ratty_terminal "$LIVE_ROOT"
    install_holyc_tools "$LIVE_ROOT"
    install_templeos_theme_assets "$LIVE_ROOT"
    write_livefs_launchers "$LIVE_ROOT"
    write_default_wallpaper "$LIVE_ROOT"
    write_fetch_branding "$LIVE_ROOT"
    configure_calamares "$LIVE_ROOT"
    configure_english_locale "$LIVE_ROOT"

    if [ "$INSTALL_RUNTIME" = "1" ]; then
        install_runtime_packages "$LIVE_ROOT"
    fi

    case "$STRIP_PROFILE" in
        none)
            ;;
        lite)
            strip_lite_profile "$LIVE_ROOT"
            ;;
        *)
            echo "ERROR: unknown STRIP_PROFILE: $STRIP_PROFILE" >&2
            echo "Valid values: none, lite" >&2
            exit 1
            ;;
    esac

    rm -f "$ISO_ROOT/live/filesystem.squashfs"
    mksquashfs "$LIVE_ROOT" "$ISO_ROOT/live/filesystem.squashfs" -comp xz -noappend
}

build_iso() {
    echo "Building ISO: $OUTPUT_ISO"
    mkdir -p "$(dirname "$OUTPUT_ISO")"
    resolve_isohybrid_mbr

    xorriso -as mkisofs \
        -r -V "$VOLUME_ID" \
        -o "$OUTPUT_ISO" \
        -J -joliet-long \
        -isohybrid-mbr "$ISOHYBRID_MBR" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot -isohybrid-gpt-basdat \
        "$ISO_ROOT"
}

echo "=== Temple4 WSL ISO Build ==="
echo "Source: $SOURCE_DIR"
echo "Work:   $WORK_DIR"
echo "Output: $OUTPUT_ISO"
echo "Mode:   $([ "$REPACK_LIVEFS" = "1" ] && echo livefs-repack || echo quick)"
echo "Strip:  $STRIP_PROFILE"
echo "Runtime install: $INSTALL_RUNTIME"

for cmd in cp find sed xorriso; do
    require_command "$cmd"
done

require_path "$SOURCE_DIR/isolinux/isolinux.bin"
require_path "$SOURCE_DIR/boot/grub/efiboot.img"
require_path "$SOURCE_DIR/live/vmlinuz"
require_path "$SOURCE_DIR/live/initrd.img"
require_path "$SOURCE_DIR/live/filesystem.squashfs"

rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT"
copy_tree "$SOURCE_DIR" "$ISO_ROOT"
soft_rebrand_iso_root

if [ "$REPACK_LIVEFS" = "1" ]; then
    repack_livefs
else
    echo "Skipping live filesystem repack. Set REPACK_LIVEFS=1 for userland injection."
fi

build_iso

if [ "$(id -u)" -eq 0 ]; then
    chown "$OWNER_UID:$OWNER_GID" "$OUTPUT_ISO" 2>/dev/null || true
    chown -R "$OWNER_UID:$OWNER_GID" "$ISO_ROOT" "$LIVE_ROOT" 2>/dev/null || true
fi

echo "Done."
echo "ISO: $OUTPUT_ISO"
