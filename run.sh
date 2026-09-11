#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
export LOWLIGHT_WORKSPACE="${LOWLIGHT_WORKSPACE:-${MIDNIGHT_WORKSPACE:-$PWD}}"
export MIDNIGHT_WORKSPACE="${MIDNIGHT_WORKSPACE:-$LOWLIGHT_WORKSPACE}"
BUILD_CONFIGURATION="${LOWLIGHT_BUILD_CONFIGURATION:-release}"
case "$BUILD_CONFIGURATION" in
  debug|release) ;;
  *) printf 'LOWLIGHT_BUILD_CONFIGURATION must be debug or release.\n' >&2; exit 1 ;;
esac
cd "$PACKAGE_ROOT"
swift build --configuration "$BUILD_CONFIGURATION" --product lowlight
BIN_DIR="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)"
exec "$BIN_DIR/lowlight" "$@"
