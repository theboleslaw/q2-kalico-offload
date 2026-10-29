#!/usr/bin/env bash
# Compatibility wrapper: the old host-only installer is now a mode of the self-contained
# bundle installer. Use ./install-klipper.sh directly for the full host + flash + camera
# installation.
#
# This wrapper only installs the host side. It never flashes an MCU and never changes the
# printer board.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install-klipper.sh" --host-only "$@"
