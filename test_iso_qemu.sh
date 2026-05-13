#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/wsl_common.sh"

require_wsl_environment "Temple4 QEMU smoke test"

ISO="${1:-$HOME/temple4_work/Temple4-runtime-lite.iso}"
MODE="${2:-bios}"
DISK="${3:-$HOME/temple4_work/temple4-test.qcow2}"
DISK_SIZE="${DISK_SIZE:-32G}"

if [ ! -f "$ISO" ]; then
    echo "ERROR: ISO not found: $ISO" >&2
    exit 1
fi

require_command_hint qemu-system-x86_64 qemu-system-x86
require_command_hint qemu-img qemu-utils

if [ ! -f "$DISK" ]; then
    echo "Creating install target disk: $DISK ($DISK_SIZE)"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi

ACCEL=("-accel" "tcg")
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL=("-enable-kvm")
fi

FIRMWARE=()
if [ "$MODE" = "uefi" ]; then
    OVMF="/usr/share/OVMF/OVMF_CODE.fd"
    if [ ! -f "$OVMF" ]; then
        echo "ERROR: UEFI mode requested but OVMF was not found at $OVMF" >&2
        exit 1
    fi
    FIRMWARE=("-bios" "$OVMF")
elif [ "$MODE" != "bios" ]; then
    echo "ERROR: mode must be 'bios' or 'uefi'" >&2
    exit 1
fi

echo "Booting $ISO in $MODE mode..."
echo "Install target disk: $DISK"
echo "Manual smoke targets:"
echo "  - live desktop reaches the session"
echo "  - installer sees the virtual disk"
echo "  - terminal and file manager open"
echo "  - Temple4 boot branding appears in BIOS/UEFI menus"
echo "  - /run/live/medium/Temple4 contains TempleOS, ZealOS, and Exodus payloads"
echo "  - shutdown works"

exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    "${FIRMWARE[@]}" \
    -m 4096 \
    -smp 4 \
    -cdrom "$ISO" \
    -drive "file=$DISK,format=qcow2,if=virtio" \
    -boot d \
    -display gtk,gl=off \
    -name "Temple4 ISO smoke test"
