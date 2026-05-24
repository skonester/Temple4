# Third-Party Notices

Temple4 is assembled from free software components. The Temple4 project does
not claim ownership over upstream Debian, GNU, Linux-libre, GRUB, Syslinux, or
other third-party components included in the source tree or generated ISO.

The built image is based on Debian Trixie userland components and a GNU
Linux-libre kernel. Package-level license information belongs to each upstream
package and should be read from the package copyright files:

```text
/usr/share/doc/*/copyright
```

Common license texts are normally available in:

```text
/usr/share/common-licenses
```

For source packages, use the upstream project or Debian source package tooling,
for example:

```bash
apt source <package-name>
```

Temple4-specific scripts, documentation, configuration, and branding assets are
licensed under GPL-3.0-or-later unless a file states otherwise.

## Bundled TempleOS-Family Tools

Ratty Terminal is bundled from the upstream `orhun/ratty` binary release and is
licensed under the MIT License. The release archive included with Temple4 keeps
Ratty's upstream `LICENSE`, `README.md`, and `CHANGELOG.md` alongside the
binary in `/opt/ratty`.

HolyC-for-Linux is bundled from `jamesalbert/HolyC-for-Linux` and is licensed
under the MIT License. Temple4 installs it under `/opt/holyc-for-linux` with a
small local `holyc` wrapper and demo launcher.

TempleOS-Theme assets are bundled from `PhilipPanda/TempleOS-Theme` and are
licensed under the MIT License. Temple4 uses the portable icon theme, cursor
theme, and `templeos_font.ttf` font assets for XFCE defaults; Openbox-specific
configuration from that project is not installed.
