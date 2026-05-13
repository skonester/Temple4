#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for the old Fedora-named helper.
# The build now supports any WSL distro with the required packages installed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/wsl_common.sh"

require_wsl_environment "Temple4 livefs build"

REPACK_LIVEFS=1 exec "$SCRIPT_DIR/build_temple4_wsl.sh" "$@"
