# Temple4

<p align="center">
  <img src="Temple4.png" alt="Temple4" width="360">
</p>

Temple4 is a compact live GNU/Linux system for exploring TempleOS-family
software from a familiar modern desktop. It combines a Debian Trixie userland,
a GNU Linux-libre kernel, XFCE, and ready-to-run launchers for TempleOS, ZealOS,
and Exodus.

The goal is simple: boot quickly, stay understandable, and keep the TempleOS
lineage close at hand without giving up practical Linux tools.

## Project Motivation

Temple4 comes from being moved by Terry A. Davis's story and work, and from a
practical problem: there was not a simple, ready-to-boot userland for exploring
and testing TempleOS-family systems in a straightforward way. Temple4 is meant
to make that first step easier by putting the live desktop, emulator launchers,
TempleOS-family payloads, and basic Linux tools in one small environment.

It is also meant to be a minimalist place for future users to play in. The goal
is not to build a large general-purpose distribution, but to provide a focused
space where people can boot, experiment, break things, learn, reinstall, and
keep going without needing to assemble the whole setup by hand.

## Highlights

- Debian Trixie base with a GNU Linux-libre kernel
- XFCE desktop with LightDM live-session autologin
- BIOS and UEFI boot support through ISOLINUX and GRUB
- TempleOS and ZealOS launchers using QEMU
- Native Exodus launcher
- Calamares installer integration
- NetSurf GTK as the default lightweight browser
- Fastfetch Temple4 branding
- Runtime-lite release profile that removes large nonessential desktop Debian payloads
- Bare-metal wallpaper helper for XFCE monitor-name differences

## Release Image

Temple4 is distributed as a downloadable ISO image. Download the current
release ISO, write it to a USB drive, boot it on a PC or virtual machine, and
use it as a live desktop or install it from the included installer.

```text
Temple4.iso
```

Current release verification:

```text
File: Temple4.iso
Size: 889,260,032 bytes
SHA256: f6124eb31b419c0881915a41de5657f4c2e8c1f70a24f97fe747dd102648cecc
```

After downloading, compare the SHA256 hash of your ISO with the value above
before writing it to removable media.

## System Profile

- Base: Debian Trixie
- Kernel: GNU Linux-libre
- Desktop: XFCE
- Display manager: LightDM
- Boot: GRUB for UEFI, ISOLINUX for BIOS
- Locale: `en_US.UTF-8`
- Keyboard layout: `us`
- Browser: `netsurf-gtk`
- Terminal: `xfce4-terminal`
- Wallpaper: `/usr/share/backgrounds/temple4/Temple4.png`

Temple4 identifies itself in boot menus, `/etc/os-release`, hostname data, and
terminal fetch tools while keeping `ID_LIKE=debian` for package compatibility.

## Live Session

The live image logs into XFCE automatically:

```text
Username: user
Password: live
Display name: Temple4 User
Home: /home/user
```

Use `sudo` for administrative access:

```bash
sudo -i
```

Root credentials are also set for environments that allow direct root login:

```text
Username: root
Password: live
```

## Included Temple Tools

Temple4 includes desktop and application-menu launchers for:

- TempleOS in QEMU
- ZealOS in QEMU
- Exodus as a native Linux application

Command-line launchers are available too:

```bash
temple4-run-templeos
temple4-run-zealos
temple4-run-exodus
```

Bundled payloads are copied into the live user's home:

```text
/home/user/Terry
```

They are also available directly from the live medium:

```text
/run/live/medium/Temple4
```

## Desktop Details

XFCE 4.18 requires executable desktop launchers to have trusted GVFS checksum
metadata. Temple4 installs an autostart helper that marks the TempleOS, ZealOS,
Exodus, and installer desktop launchers as trusted at session start:

```text
/etc/xdg/autostart/temple4-trust-desktop-launchers.desktop
```

The runtime-lite profile removes stock wallpaper collections and keeps only the
Temple4 wallpaper. XFCE-compatible paths are retained as symlinks:

```text
/usr/share/backgrounds/temple4/Temple4.png
/usr/share/backgrounds/xfce/Temple4.png
/usr/share/xfce4/backdrops/Temple4.png
```

An XFCE autostart helper reapplies the wallpaper after login and detects real
XRandR monitor names such as `HDMI-1`, `DP-1`, and `eDP-1`, which helps keep the
background correct on both VMs and bare metal:

```text
/etc/xdg/autostart/temple4-apply-wallpaper.desktop
```

## Installer

Temple4 uses Calamares to install the live system to a drive. You can install
Temple4 to an internal SSD, an external SSD, or a USB flash drive, depending on
what you want to boot from.

Launch the installer from the desktop, the app menu, or the terminal:

```bash
temple4-install
```

The old `calamares-install-debian` entry is kept as a compatibility wrapper for
systems or launchers that still look for the Debian live installer command.

### USB and SSD Install Notes

Installing to a USB drive or SSD can complete successfully even if the system
does not boot afterward. In that case, the important part is that the payload
was written: the live filesystem, Temple4 desktop files, Temple-family payloads,
and installed userland can be present on the target drive while the firmware
still fails before it reaches them. Then reboot as this is likely a false flag install failure due to tweaks I made in the config that aren't Debian defaults. 


## Runtime-Lite Profile

The downloadable release uses the runtime-lite profile. It keeps the core
desktop and Temple tools while leaving out larger nonessential packages and
cached payloads, including:

- Firefox
- VLC and Audacious
- CUPS printing services
- Bluetooth/BlueZ
- Gnumeric, Geany, LazPaint, Ristretto, and Sylpheed
- CJK input/font packages
- Older non-booted kernel payloads
- Stock XFCE wallpapers
- Man pages, documentation, package caches, and extra locales

Removed software can be reinstalled later with `sudo apt install`.

## Building On Windows With WSL

The build scripts are intended to run from Windows through WSL. They do not
require a specific WSL distro; Ubuntu, Debian, Fedora, Arch, and similar WSL
environments are fine as long as the required packages are installed.

From PowerShell, install WSL if you do not already have it:

```powershell
wsl --install
```

Restart if Windows asks you to, then open your WSL distro and install the
basic build tools for that distro.

Debian or Ubuntu WSL:

```bash
sudo apt update
sudo apt install -y git git-lfs xorriso squashfs-tools rsync qemu-system-x86 qemu-utils ovmf
```

Fedora WSL:

```bash
sudo dnf install -y git git-lfs xorriso squashfs-tools rsync qemu-system-x86 qemu-img edk2-ovmf
```

Clone the repo from inside WSL, enter it, and pull the Git LFS assets:

```bash
git clone <repo-url> OpenTexas
cd OpenTexas
git lfs install
git lfs pull
```

Build the runtime-lite ISO:

```bash
./full_build_wsl.sh
```

The output defaults to:

```text
~/temple4_work/Temple4-runtime-lite.iso
```

For a fast boot-menu-only rebuild that skips the live filesystem repack, run:

```bash
./build_temple4_wsl.sh
```

To smoke-test the ISO in QEMU from WSL, run:

```bash
./test_iso_qemu.sh
```

The scripts check that they are running in WSL and print package-install hints
when a required command is missing. Set `ALLOW_NON_WSL=1` only if you
intentionally want to run the same scripts on a regular Linux host.

## License

Temple4 project scripts, documentation, configuration, and branding assets are
licensed under `GPL-3.0-or-later` unless a file states otherwise.

Temple4 also includes third-party free software from Debian GNU/Linux, GNU,
Linux-libre, GRUB, Syslinux, and other upstream projects. Those components keep
their original upstream licenses. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.


## Project Goal

Temple4 is not a replacement for TempleOS. It is a fourth temple around it: a
small live Debian and Linux-libre environment that makes TempleOS, ZealOS, and
Exodus easy to boot, inspect, copy, install, and preserve from a modern desktop.
