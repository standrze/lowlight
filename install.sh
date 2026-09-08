#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: ./install.sh [--configuration debug|release] [--prefix PATH]
       ./install.sh --binary PATH [--prefix PATH]

Build and install lowlight without moving its source project.

  --configuration NAME  Swift build configuration (default: debug).
  --binary PATH         Install a prebuilt executable without building.
                        Its SwiftPM resource bundles must be beside it.
  --prefix PATH         Installation home (default: ~/.lowlight).
  --help                Show this help.

The stable command is PREFIX/bin/lowlight. Each install stages a complete
binary and its resources, then atomically updates PREFIX/lib/lowlight. Previous
builds remain in PREFIX/lib/.lowlight-versions for running applications.

Recognized launchers from the previous chat client installation are updated to
forward to lowlight. Other midnight and midnight-chat commands are left intact.
With the default installation, a recognized ~/.midnight/bin/lowlight launcher
also forwards to ~/.lowlight/bin/lowlight. An explicit --prefix only changes
launchers inside that prefix.

Creates bin, lib, logs, and sessions/chat without replacing their
existing contents. --prefix changes the installation layout only; chat data
defaults to ~/.lowlight/sessions/chat and also reads previous session locations.
Use the application's --sessions-directory option for another session location.
No shell profile or startup items change.
HELP
}

fail() {
  printf 'lowlight install: %s\n' "$*" >&2
  exit 1
}

write_launcher() {
  cat <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER_DIRECTORY="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
APP_DIRECTORY="$(CDPATH= cd "$LAUNCHER_DIRECTORY/../lib/lowlight" && pwd -P)"
export LOWLIGHT_WORKSPACE="${LOWLIGHT_WORKSPACE:-${MIDNIGHT_WORKSPACE:-$PWD}}"
export MIDNIGHT_WORKSPACE="${MIDNIGHT_WORKSPACE:-$LOWLIGHT_WORKSPACE}"
exec "$APP_DIRECTORY/lowlight" "$@"
LAUNCHER
}

write_compat_launcher() {
  cat <<'LAUNCHER'
#!/usr/bin/env bash
# lowlight compatibility launcher (managed by lowlight install.sh).
set -euo pipefail
LAUNCHER_DIRECTORY="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
exec "$LAUNCHER_DIRECTORY/lowlight" "$@"
LAUNCHER
}

write_previous_home_launcher() {
  cat <<'LAUNCHER'
#!/usr/bin/env bash
# lowlight home compatibility launcher (managed by lowlight install.sh).
set -euo pipefail
LAUNCHER_DIRECTORY="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
exec "$LAUNCHER_DIRECTORY/../../.lowlight/bin/lowlight" "$@"
LAUNCHER
}

write_previous_chat_launcher() {
  cat <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
LAUNCHER_DIRECTORY="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
APP_DIRECTORY="$(CDPATH= cd "$LAUNCHER_DIRECTORY/../lib/midnight" && pwd -P)"
export MIDNIGHT_WORKSPACE="${MIDNIGHT_WORKSPACE:-$PWD}"
exec "$APP_DIRECTORY/midnight" "$@"
LAUNCHER
}

is_managed_chat_launcher() {
  # Match the entire known chat launcher, never a runner or custom command.
  [[ -f "$1" && ! -L "$1" ]] || return 1
  cmp -s "$1" <(write_previous_chat_launcher) || cmp -s "$1" <(write_compat_launcher)
}

PACKAGE_ROOT="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
PREFIX="${HOME:?HOME must be set}/.lowlight"
PREFIX_SET=false
CONFIGURATION=debug
CONFIGURATION_SET=false
BINARY=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || fail '--configuration requires debug or release'
      CONFIGURATION="$2"
      CONFIGURATION_SET=true
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 && -n "$2" ]] || fail '--prefix requires a path'
      PREFIX="$2"
      PREFIX_SET=true
      shift 2
      ;;
    --binary)
      [[ $# -ge 2 && -n "$2" ]] || fail '--binary requires a path'
      BINARY="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *) fail '--configuration must be debug or release' ;;
esac
if [[ -n "$BINARY" ]]; then
  [[ "$CONFIGURATION_SET" == false ]] || fail '--binary cannot be combined with --configuration'
else
  swift build --package-path "$PACKAGE_ROOT" --configuration "$CONFIGURATION" --product lowlight
  BUILD_DIRECTORY="$(swift build --package-path "$PACKAGE_ROOT" --configuration "$CONFIGURATION" --show-bin-path)"
  BINARY="$BUILD_DIRECTORY/lowlight"
fi

[[ -f "$BINARY" && -x "$BINARY" ]] || fail "executable not found: $BINARY"
BINARY_DIRECTORY="$(CDPATH= cd "$(dirname "$BINARY")" && pwd -P)"
BINARY="$BINARY_DIRECTORY/$(basename "$BINARY")"
[[ -d "$BINARY_DIRECTORY/swift-tui_SwiftTUIWebHost.bundle" ]] || fail 'missing swift-tui_SwiftTUIWebHost.bundle beside the executable'

umask 077
mkdir -p "$PREFIX"
PREFIX="$(CDPATH= cd "$PREFIX" && pwd -P)"
mkdir -p "$PREFIX/lib" "$PREFIX/bin" "$PREFIX/logs" "$PREFIX/sessions/chat"
LOCK_DIRECTORY="$PREFIX/lib/.lowlight-install.lock"
mkdir "$LOCK_DIRECTORY" 2>/dev/null || fail "another install may be running; lock exists at $LOCK_DIRECTORY"

STAGED_DIRECTORY=
APP_LINK_TEMP=
LAUNCHER_TEMP=
COMPAT_LAUNCHER_TEMP=
PUBLISHED=false
cleanup() {
  [[ -z "$APP_LINK_TEMP" ]] || rm -f "$APP_LINK_TEMP"
  [[ -z "$LAUNCHER_TEMP" ]] || rm -f "$LAUNCHER_TEMP"
  [[ -z "$COMPAT_LAUNCHER_TEMP" ]] || rm -f "$COMPAT_LAUNCHER_TEMP"
  if [[ "$PUBLISHED" == false && -n "$STAGED_DIRECTORY" ]]; then
    rm -rf "$STAGED_DIRECTORY"
  fi
  rmdir "$LOCK_DIRECTORY"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP_LINK="$PREFIX/lib/lowlight"
if [[ -L "$APP_LINK" ]]; then
  case "$(readlink "$APP_LINK")" in
    .lowlight-versions/install.*) ;;
    *) fail "refusing to replace an unmanaged app link: $APP_LINK" ;;
  esac
elif [[ -e "$APP_LINK" ]]; then
  fail "refusing to replace an existing app file or directory: $APP_LINK"
fi
if [[ -e "$PREFIX/bin/lowlight" || -L "$PREFIX/bin/lowlight" ]]; then
  [[ -f "$PREFIX/bin/lowlight" && ! -L "$PREFIX/bin/lowlight" ]] &&
    cmp -s "$PREFIX/bin/lowlight" <(write_launcher) ||
    fail "refusing to replace an unmanaged command: $PREFIX/bin/lowlight"
fi

mkdir -p "$PREFIX/lib/.lowlight-versions"
STAGED_DIRECTORY="$(mktemp -d "$PREFIX/lib/.lowlight-versions/install.XXXXXXXX")"
install -m 755 "$BINARY" "$STAGED_DIRECTORY/lowlight"
for RESOURCE_BUNDLE in "$BINARY_DIRECTORY"/*.bundle; do
  [[ -d "$RESOURCE_BUNDLE" ]] || continue
  cp -R "$RESOURCE_BUNDLE" "$STAGED_DIRECTORY/"
done

LAUNCHER_TEMP="$(mktemp "$PREFIX/bin/.lowlight.XXXXXXXX")"
write_launcher > "$LAUNCHER_TEMP"
chmod 755 "$LAUNCHER_TEMP"

APP_LINK_TEMP="$PREFIX/lib/.lowlight-link.$(basename "$STAGED_DIRECTORY")"
ln -s ".lowlight-versions/$(basename "$STAGED_DIRECTORY")" "$APP_LINK_TEMP"
# macOS mv -h replaces the destination symlink instead of following it.
mv -fh "$APP_LINK_TEMP" "$APP_LINK"
APP_LINK_TEMP=
PUBLISHED=true
mv -fh "$LAUNCHER_TEMP" "$PREFIX/bin/lowlight"
LAUNCHER_TEMP=

for LEGACY_NAME in midnight midnight-chat; do
  if is_managed_chat_launcher "$PREFIX/bin/$LEGACY_NAME"; then
    COMPAT_LAUNCHER_TEMP="$(mktemp "$PREFIX/bin/.$LEGACY_NAME.XXXXXXXX")"
    write_compat_launcher > "$COMPAT_LAUNCHER_TEMP"
    chmod 755 "$COMPAT_LAUNCHER_TEMP"
    mv -fh "$COMPAT_LAUNCHER_TEMP" "$PREFIX/bin/$LEGACY_NAME"
    COMPAT_LAUNCHER_TEMP=
    printf 'Updated previous chat command: %s\n' "$PREFIX/bin/$LEGACY_NAME"
  fi
done

# Default installs keep our previous command location working without changing
# runner commands or launchers outside an explicitly requested prefix.
if [[ "$PREFIX_SET" == false ]]; then
  PREVIOUS_LAUNCHER="$HOME/.midnight/bin/lowlight"
  if [[ -f "$PREVIOUS_LAUNCHER" && ! -L "$PREVIOUS_LAUNCHER" &&
        ! "$PREVIOUS_LAUNCHER" -ef "$PREFIX/bin/lowlight" ]] &&
      cmp -s "$PREVIOUS_LAUNCHER" <(write_launcher); then
    COMPAT_LAUNCHER_TEMP="$(mktemp "$HOME/.midnight/bin/.lowlight.XXXXXXXX")"
    write_previous_home_launcher > "$COMPAT_LAUNCHER_TEMP"
    chmod 755 "$COMPAT_LAUNCHER_TEMP"
    mv -fh "$COMPAT_LAUNCHER_TEMP" "$PREVIOUS_LAUNCHER"
    COMPAT_LAUNCHER_TEMP=
    printf 'Updated previous lowlight command: %s\n' "$PREVIOUS_LAUNCHER"
  fi
fi

printf 'Installed lowlight: %s\n' "$PREFIX/lib/lowlight/lowlight"
printf 'Launch from any workspace: %s\n' "$PREFIX/bin/lowlight"
