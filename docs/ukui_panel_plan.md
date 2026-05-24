# Implementation Plan: Standalone `ukui-panel` Integration in XFCE

This document outlines the design and implementation plan to replace the default `xfce4-panel` with the Qt-based `ukui-panel` from the UKUI Desktop Environment, and programmatically map all Temple4 desktop launchers (e.g., TempleOS, ZealOS, Exodus, HolyC Demo) to the panel's quicklaunch taskbar at the bottom.

---

## 1. Architectural & Dependency Analysis

`ukui-panel` is a Qt5-based taskbar component. To run it standalone inside an XFCE session without installing the entire UKUI desktop environment, we must satisfy its core library and configuration dependencies.

### A. Required Packages & Libraries
The following packages must be installed inside the target system's SquashFS:
*   **`ukui-panel`**: The taskbar component itself.
*   **`ukui-settings-daemon`**: Handles panel system integration, themes, and global settings.
*   **`libgsettings-qt1`**: Allows the Qt5 application to query and write settings to the GSettings (dconf) backend.
*   **`dconf-cli` / `dconf-gsettings-backend`**: Backend database storage for UKUI configuration keys.
*   **`libkysdk-applications`**: Kylin SDK runtime libraries (dependency of newer `ukui-panel` builds).

### B. Pinning Configuration Mechanics
`ukui-panel` supports a "Quicklaunch" / Pinned Applications section. Depending on the packaging version, pinned applications are configured in one of two ways:
1.  **GSettings/dconf Scheme**:
    *   Schema: `org.ukui.panel.quicklaunch` (or `org.ukui.panel.settings`)
    *   Key: `favorites` or `pinned-apps`
    *   Type: Array of desktop file IDs or absolute paths, e.g., `['/usr/share/applications/temple4-run-templeos.desktop', '/usr/share/applications/temple4-holyc-demo.desktop']`.
2.  **Configuration File**:
    *   Path: `~/.config/ukui/panel.conf`
    *   Contains applet-specific lists of pinned launcher items.

---

## 2. Proposed Changes

### A. Build Script Adjustments
We will modify [build_temple4_wsl.sh](file:///c:/Users/admin/Documents/GitHub/Temple4/build_temple4_wsl.sh) to include the new packages and configuration files.

#### 1. Add UKUI Panel Packages to installation list
We will append the required UKUI packages and GSettings dependencies to the `apt-get install` command inside the `install_runtime_packages` function:
```bash
ukui-panel ukui-settings-daemon libgsettings-qt1 dconf-cli
```

---

### B. Disable Default XFCE Panel
To prevent XFCE from starting the standard `xfce4-panel` session manager component:

#### 1. Session Autostart Overrides
Inside `$LIVE_ROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml` (or by using custom autostart overrides), we will disable `xfce4-panel` by removing it from the session client list or setting its restart style to `0` (never).
Alternatively, we can mask or delete `/etc/xdg/autostart/xfce4-panel.desktop` inside the SquashFS.

---

### C. Configure `ukui-panel` Standalone Autostart
We will create a desktop autostart entry inside `/etc/skel/.config/autostart/` to trigger `ukui-panel` when the user logs into XFCE.

#### [NEW] `/etc/skel/.config/autostart/ukui-panel.desktop`
```ini
[Desktop Entry]
Type=Application
Name=UKUI Panel Standalone
Comment=Start UKUI panel instead of XFCE panel
Exec=ukui-panel
OnlyShowIn=XFCE;
RunHook=0
StartupNotify=false
Terminal=false
Hidden=false
```

---

### D. Dynamic Icon Pining & Initialization Script
We will write a shell script to automate copying and mapping desktop icons to the panel. This script will run on the first login of the user.

#### [NEW] `/usr/local/bin/temple4-panel-init.sh`
```bash
#!/bin/bash
# Temple4 Panel Initialization and Icon Mapping Script
set -e

# Wait for dconf/gsettings daemon to become available
sleep 2

DESKTOP_DIR="$HOME/Desktop"
PANEL_CONFIG_DIR="$HOME/.config/ukui"
mkdir -p "$PANEL_CONFIG_DIR"

# 1. Identify all Temple4 launchers on the user's Desktop
LAUNCHERS=()
for desktop_file in "$DESKTOP_DIR"/*.desktop; do
    [ -e "$desktop_file" ] || continue
    # Resolve absolute path or standard location
    LAUNCHERS+=("'$desktop_file'")
done

# 2. Format as a GSettings array list: ['/path/to/1.desktop', '/path/to/2.desktop']
if [ ${#LAUNCHERS[@]} -gt 0 ]; then
    FAVORITES_ARRAY=$(printf ", %s" "${LAUNCHERS[@]}")
    FAVORITES_ARRAY="[${FAVORITES_ARRAY:2}]"
    
    # Write to GSettings database for ukui-panel
    if gsettings list-schemas | grep -q "org.ukui.panel.quicklaunch"; then
        gsettings set org.ukui.panel.quicklaunch favorites "$FAVORITES_ARRAY" || true
    fi
    
    # Fallback: Populate panel.conf config file if GSettings keys are not bound
    cat > "$PANEL_CONFIG_DIR/panel.conf" <<EOF
[QuickLaunch]
apps=${FAVORITES_ARRAY}
position=bottom
EOF
fi

# 3. Disable XFCE Desktop Icons to prevent duplicate shortcuts
# Style 0 = None (hides all icons on the desktop screen)
xfconf-query -c xfce4-desktop -p /desktop-icons/style -s 0 || true
```

We will set executable permissions (`chmod +x`) on this script and trigger it via an autostart desktop entry at `/etc/skel/.config/autostart/temple4-panel-init.desktop`.

---

## 3. Verification & Testing Plan

### A. Package & Build Check
*   Ensure that the `build_temple4_wsl.sh` remaster script executes under WSL without dependency failures while installing `ukui-panel` packages.

### B. Boot and Launch Validation
*   Boot the generated ISO.
*   Verify that `xfce4-panel` does not load.
*   Verify that `ukui-panel` starts at the bottom of the screen.
*   Verify that the standard desktop icons (HolyC Demo, Installer, Emulators) are hidden from the desktop surface and appear pinned inside the Quicklaunch area of the `ukui-panel`.
