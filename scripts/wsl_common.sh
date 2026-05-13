#!/usr/bin/env bash

is_wsl() {
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null ||
        grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null
}

wsl_install_hint() {
    local packages="$1"

    if command -v apt-get >/dev/null 2>&1; then
        echo "Install them with: sudo apt update && sudo apt install -y $packages" >&2
    elif command -v dnf >/dev/null 2>&1; then
        echo "Install them with: sudo dnf install -y $packages" >&2
    elif command -v pacman >/dev/null 2>&1; then
        echo "Install them with: sudo pacman -S --needed $packages" >&2
    elif command -v zypper >/dev/null 2>&1; then
        echo "Install them with: sudo zypper install $packages" >&2
    else
        echo "Install the missing packages with your WSL distro's package manager." >&2
    fi
}

require_wsl_environment() {
    local name="$1"

    if ! is_wsl && [ "${ALLOW_NON_WSL:-0}" != "1" ]; then
        echo "ERROR: $name is intended to run inside WSL." >&2
        echo "Open a WSL shell, cd to this repo, and run the script again." >&2
        echo "Set ALLOW_NON_WSL=1 to run on a regular Linux host anyway." >&2
        exit 1
    fi
}

require_command_hint() {
    local command_name="$1"
    local package_hint="${2:-$1}"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: required command is missing: $command_name" >&2
        wsl_install_hint "$package_hint"
        exit 1
    fi
}
