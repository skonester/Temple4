#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for the canonical Temple4 runtime-lite build.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/wsl_common.sh"

require_wsl_environment "Temple4 full build"

export INSTALL_RUNTIME="${INSTALL_RUNTIME:-1}"
export STRIP_PROFILE="${STRIP_PROFILE:-lite}"
export OUTPUT_ISO="${OUTPUT_ISO:-$HOME/temple4_work/Temple4-runtime-lite.iso}"

exec "$SCRIPT_DIR/build_temple4_wsl.sh" "$@"
