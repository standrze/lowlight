#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
export LOWLIGHT_WORKSPACE="${LOWLIGHT_WORKSPACE:-${MIDNIGHT_WORKSPACE:-$PWD}}"
export MIDNIGHT_WORKSPACE="${MIDNIGHT_WORKSPACE:-$LOWLIGHT_WORKSPACE}"
cd "$PACKAGE_ROOT"
swift build --product lowlight
BIN_DIR="$(swift build --show-bin-path)"
exec "$BIN_DIR/lowlight" "$@"
