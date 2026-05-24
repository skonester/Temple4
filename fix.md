# Nouveau Hardware Acceleration & UEFI Target System Fixes Post-Mortem

This document outlines the post-mortem analysis of the boot loader and graphics failures introduced during the Temple4 configuration, the exact root causes, and the implemented fixes to ensure a working system with hardware-accelerated graphics (NVK/Zink/Nouveau) on the installed target.

---

## 1. Post-Mortem of the Failures & Root Causes

### A. UEFI Bootloader Drop to `grub>` Command Prompt
*   **The Failure**: When booting the installed target system under UEFI mode, the system failed to boot and dropped immediately to the interactive `grub>` command line.
*   **The Root Cause**: During branding customization, the Calamares `bootloaderEntryName` was changed from `Debian` to `Temple4`. This caused Calamares to register the UEFI bootloader and write its configuration files to `/EFI/Temple4/` on the EFI System Partition (ESP). However, the Debian GRUB package installation is hardcoded to look for its boot config files under `/EFI/debian/`. The directory mismatch broke the path resolution, leaving GRUB unable to load its configuration.
*   **The Fix**: Reverted the Calamares `branding.desc` configuration in the build script to use `bootloaderEntryName: debian` (lowercase), keeping the EFI path aligned with the Debian package expectation.

### B. Graphics Boot Drop to Console Bash Prompt
*   **The Failure**: The installed target system booted the kernel but failed to start the graphical desktop, dropping the user to a console bash prompt.
*   **The Root Cause**:
    1.  **Missing Nvidia Graphics Firmware**: We only installed `firmware-misc-nonfree`. However, in modern Debian repositories (Bookworm/Trixie), the binary firmware blobs required for NVIDIA GPU chips under the open-source Nouveau driver are located in `firmware-nvidia-graphics`. Without it, the Nouveau driver failed to load its firmware and initialize modesetting.
    2.  **No Fallback Graphics Pipeline**: To prevent the system from using CPU-based software rendering (`llvmpipe`), we deleted the software Vulkan driver (`lvp_icd.*.json`) and exported `LIBGL_ALWAYS_SOFTWARE=0`. Because the hardware Nvidia driver failed to load due to missing firmware, and software fallback rendering was blocked, the graphics pipeline completely crashed, preventing X11/LightDM from starting.
*   **The Fix**:
    1.  Added `firmware-nvidia-graphics` to the live SquashFS package list to supply the necessary Nvidia firmware blobs.
    2.  Maintained the strict software-rendering blocks (`lvp` deletion and `LIBGL_ALWAYS_SOFTWARE=0`) to ensure the system is locked to hardware acceleration, which now initializes successfully because the driver can load its firmware.

### C. Live ISO BIOS Boot Menu Drop to `boot:` Prompt
*   **The Failure**: When booting the live ISO in BIOS mode, the ISOLINUX bootloader failed to load the kernel and dropped to a `boot:` prompt.
*   **The Root Cause**: The kernel mode-setting argument `nouveau.modeset=1` was appended directly to the `kernel` directive line in `isolinux/live.cfg`. ISOLINUX treats everything after `kernel` as the path to the executable file, failing to boot because it searched for a file named `"/live/vmlinuz nouveau.modeset=1"`.
*   **The Fix**: Reverted the live bootloader configurations (`grub.cfg` and `live.cfg`) back to their clean original states, separating kernel paths from their `append` parameters and restoring proper `nomodeset` safety flags to failsafe modes.

---

## 2. Target Graphics and Driver Propagation

To prevent the target installed system from falling back to CPU-based software rendering (`llvmpipe`), the following configurations are maintained inside the SquashFS and Calamares templates:

### A. GRUB Kernel Mode Setting (KMS) & Blacklists
The main `/etc/default/grub` configuration in the SquashFS is explicitly injected with the correct modesetting and blacklist parameters:
```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nouveau.modeset=1 modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm nvidia-drm.modeset=0"
```
*   **nouveau.modeset=1**: Enables Kernel Mode Setting (KMS) for the open-source Nouveau driver, required for hardware graphics initialization on modern Nvidia cards (Maxwell to Ada Lovelace).
*   **modprobe.blacklist**: Prevents any proprietary NVIDIA kernel modules from claiming the hardware.

### B. Calamares Module Overrides
To ensure Calamares does not strip these parameters when writing a new `/etc/default/grub` on the target system, custom module files are created in the SquashFS:
*   **`/etc/calamares/modules/grubcfg.conf`**:
    ```yaml
    ---
    prefer_grub_d: false
    keep_distributor: true
    kernel_params: [ "quiet", "splash", "nouveau.modeset=1", "modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm", "nvidia-drm.modeset=0" ]
    ```
*   **`/etc/calamares/modules/bootloader.conf`**:
    ```yaml
    kernelParams: [ "quiet", "splash", "nouveau.modeset=1", "modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm", "nvidia-drm.modeset=0" ]
    ```

### C. Calamares Post-Install Hook (`shellprocess`)
The Calamares installer sequence runs the `shellprocess` module inside the target chroot right before unmounting the disk:
1.  **Deletes Software Vulkan ICDs**: `rm -f /usr/share/vulkan/icd.d/lvp_icd.*.json` (removes the LLVMpipe Vulkan driver so Zink does not bind to it).
2.  **Removes Failsafe remnants**: `sed -i 's/\bnomodeset\b/ /g' /etc/default/grub` (removes any safe-graphics boot flags).
3.  **Regenerates GRUB**: `update-grub` (writes the final `/boot/grub/grub.cfg` with the correct parameters).
4.  **Regenerates initramfs**: `update-initramfs -u -k all` (compiles the Nouveau module and GSP firmware directly into the target boot image).

### D. Global Environment Variables
Mesa rendering overrides are written directly to `/etc/environment` in the SquashFS to force X11/Xorg:
```text
GDK_BACKEND=x11
QT_QPA_PLATFORM=xcb
SDL_VIDEODRIVER=x11
WINIT_UNIX_BACKEND=x11
MOZ_ENABLE_WAYLAND=0
LIBGL_ALWAYS_SOFTWARE=0
```