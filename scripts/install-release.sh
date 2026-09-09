#!/usr/bin/env bash
set -euo pipefail

VERSION=v0.1.0-beta.1
REPOSITORY=standrze/lowlight
PREFIX="${HOME:?HOME must be set}/.lowlight"
UPDATE_PATH=true
PREFIX_SET=false
fail() { printf 'lowlight: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || fail '--version requires a tag'; VERSION="$2"; shift 2 ;;
    --prefix) [[ $# -ge 2 && -n "$2" ]] || fail '--prefix requires a path'; PREFIX="$2"; PREFIX_SET=true; shift 2 ;;
    --no-path) UPDATE_PATH=false; shift ;;
    --help|-h) printf 'Usage: install-release.sh [--version TAG] [--prefix PATH] [--no-path]\n'; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail 'invalid release tag'
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) PLATFORM=macos-arm64 ;;
  Linux/x86_64) PLATFORM=linux-x86_64 ;;
  *) fail "no prebuilt release for $(uname -s)/$(uname -m); see the source build instructions" ;;
esac
ARCHIVE="lowlight-$VERSION-$PLATFORM.tar.gz"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lowlight-download.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
  gh release download "$VERSION" --repo "$REPOSITORY" --pattern "$ARCHIVE" --pattern SHA256SUMS --dir "$WORK"
else
  command -v curl >/dev/null 2>&1 || fail 'install GitHub CLI (gh) or curl first'
  BASE="https://github.com/$REPOSITORY/releases/download/$VERSION"
  curl -fL --retry 3 "$BASE/$ARCHIVE" -o "$WORK/$ARCHIVE" || fail 'download failed; private repositories require gh auth login'
  curl -fL --retry 3 "$BASE/SHA256SUMS" -o "$WORK/SHA256SUMS"
fi
EXPECTED="$(awk -v file="$ARCHIVE" '$2 == file { print $1 }' "$WORK/SHA256SUMS")"
[[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'missing or invalid checksum'
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$WORK/$ARCHIVE" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "$WORK/$ARCHIVE" | awk '{print $1}')"
fi
[[ "$ACTUAL" == "$EXPECTED" ]] || fail 'checksum mismatch; nothing installed'
tar -xzf "$WORK/$ARCHIVE" -C "$WORK"
BUNDLE="$WORK/${ARCHIVE%.tar.gz}"
[[ -f "$BUNDLE/install.sh" && -x "$BUNDLE/payload/lowlight" ]] || fail 'incomplete release archive'
# Report missing runtime libraries before modifying the existing installation.
if [[ -d "$BUNDLE/payload/runtime" ]]; then
  LD_LIBRARY_PATH="$BUNDLE/payload/runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$BUNDLE/payload/lowlight" --version
else
  "$BUNDLE/payload/lowlight" --version
fi
if [[ "$PREFIX_SET" == true ]]; then
  LOWLIGHT_MODIFY_PATH=false bash "$BUNDLE/install.sh" --prefix "$PREFIX"
else
  LOWLIGHT_MODIFY_PATH=false bash "$BUNDLE/install.sh"
fi
PREFIX="$(CDPATH= cd "$PREFIX" && pwd -P)"
if [[ "$UPDATE_PATH" == true ]]; then
  case "${SHELL:-}" in
    */zsh) RC="$HOME/.zshrc" ;;
    */bash) RC="$HOME/.bashrc" ;;
    *) RC= ;;
  esac
  if [[ -n "$RC" ]]; then
    if [[ "$PREFIX_SET" == false || "$PREFIX" == "$HOME/.lowlight" ]]; then
      ENTRY='export PATH="$HOME/.lowlight/bin:$PATH"'
    else
      printf -v ENTRY 'export PATH=%q:"$PATH"' "$PREFIX/bin"
    fi
    if ! grep -Fqx "$ENTRY" "$RC" 2>/dev/null; then
      mkdir -p "$PREFIX/backups"
      if [[ -f "$RC" ]]; then cp -p "$RC" "$PREFIX/backups/$(basename "$RC").before-lowlight.$(date +%Y%m%d%H%M%S).$$"; fi
      printf '\n# lowlight\n%s\n' "$ENTRY" >> "$RC"
    fi
    printf 'PATH configured in %s. Open a new terminal, then run lowlight.\n' "$RC"
  else
    printf 'Add %s to your shell PATH, then run lowlight.\n' "$PREFIX/bin"
  fi
fi
