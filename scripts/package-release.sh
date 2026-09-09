#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)"
VERSION="${1:?Usage: package-release.sh VERSION BUILD_DIRECTORY OUTPUT_DIRECTORY}"
BUILD="$(CDPATH= cd "${2:?missing build directory}" && pwd -P)"
OUTPUT="${3:?missing output directory}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || exit 1
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) PLATFORM=macos-arm64 ;;
  Linux/x86_64) PLATFORM=linux-x86_64 ;;
  *) printf 'Unsupported build platform\n' >&2; exit 1 ;;
esac
mkdir -p "$OUTPUT"
OUTPUT="$(CDPATH= cd "$OUTPUT" && pwd -P)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lowlight-package.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
NAME="lowlight-$VERSION-$PLATFORM"
BUNDLE="$STAGE/$NAME"
mkdir -p "$BUNDLE/payload" "$BUNDLE/licenses"
cp "$ROOT/install.sh" "$ROOT/README.md" "$ROOT/BRANDING.md" "$ROOT/CONTEXT.md" "$ROOT/LICENSE" "$BUNDLE/"
cp -R "$ROOT/branding" "$BUNDLE/"
cp "$BUILD/lowlight" "$BUNDLE/payload/"
for resource in "$BUILD"/*.bundle "$BUILD"/*.resources; do
  [[ -d "$resource" ]] && cp -R "$resource" "$BUNDLE/payload/"
done
for checkout in "$ROOT/.build/checkouts"/*; do
  [[ -d "$checkout" ]] || continue
  mkdir -p "$BUNDLE/licenses/$(basename "$checkout")"
  for license in "$checkout"/LICENSE* "$checkout"/NOTICE* "$checkout"/COPYING*; do
    [[ -f "$license" ]] && cp "$license" "$BUNDLE/licenses/$(basename "$checkout")/"
  done
done
if [[ "$PLATFORM" == linux-* ]]; then
  mkdir -p "$BUNDLE/payload/runtime"
  # ldd includes transitive dependencies. Bundle the toolchain's runtime,
  # leaving the distribution's libc/curl/TLS libraries to the OS package manager.
  while IFS= read -r library; do
    [[ -f "$library" ]] && cp -L "$library" "$BUNDLE/payload/runtime/"
  done < <(ldd "$BUILD/lowlight" | awk '$3 ~ /\/lib\/swift\/linux\// {print $3}')
  # Swiftly exposes a launcher, so discover the active toolchain from Swift itself.
  TOOLCHAIN_SHARE="$(swift -print-target-info | python3 -c 'import json, sys; from pathlib import Path; print(Path(json.load(sys.stdin)["paths"]["runtimeResourcePath"]).parent.parent / "share/swift")')"
  cp "$TOOLCHAIN_SHARE/LICENSE.txt" "$BUNDLE/licenses/Swift-LICENSE.txt"
  [[ -f "$BUNDLE/payload/runtime/libswiftCore.so" ]] || { printf 'Swift runtime was not bundled\n' >&2; exit 1; }
fi
[[ "$("$BUNDLE/payload/lowlight" --version)" == "${VERSION#v}" ]]
COPYFILE_DISABLE=1 tar -czf "$OUTPUT/$NAME.tar.gz" -C "$STAGE" "$NAME"
printf '%s\n' "$OUTPUT/$NAME.tar.gz"
