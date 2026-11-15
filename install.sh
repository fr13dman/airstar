#!/usr/bin/env bash
# Builds airstar-cli in release mode and installs it for every user on this Mac.
#
#   ./install.sh                       build and install to /usr/local/bin
#   ./install.sh --prefix /usr/local/bin
#   ./install.sh --uninstall
#
# /usr/local/bin is not on macOS's default PATH, so the installer registers it in
# /etc/paths.d, which path_helper reads for every user's login shell.

set -euo pipefail

BINARY_NAME="airstar-cli"
PREFIX="/usr/local/bin"
ACTION="install"
CONFIGURE_PATH=1
SKIP_BUILD=0
MIN_MACOS_MAJOR=14

# Overridable so the test script can exercise PATH registration without root.
PATHS_FILE="${AIRSTAR_PATHS_FILE:-/etc/paths}"
PATHS_D="${AIRSTAR_PATHS_D:-/etc/paths.d}"
PATHS_ENTRY="$PATHS_D/$BINARY_NAME"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Builds $BINARY_NAME (swift build -c release) and installs it so any user can run it.

Options:
  --prefix DIR    Install directory (default: $PREFIX)
  --no-path       Do not register DIR in $PATHS_D
  --skip-build    Install the existing release build without rebuilding
  --uninstall     Remove the installed binary and PATH registration
  -h, --help      Show this help
EOF
}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            [[ $# -ge 2 && -n "$2" ]] || die "--prefix needs a directory"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --no-path) CONFIGURE_PATH=0; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

PREFIX="${PREFIX%/}"
[[ "$PREFIX" == /* ]] || die "--prefix must be an absolute path"
TARGET="$PREFIX/$BINARY_NAME"

# Runs a command directly when we can write to its destination, otherwise through sudo.
# $1 is the path whose writability decides.
as_owner() {
    local path="$1"
    shift
    local probe="$path"
    while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
    if [[ -w "$probe" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# The Swift build must not run as root, or .build ends up owned by root.
run_as_invoking_user() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

path_registered() {
    grep -qxF "$PREFIX" "$PATHS_FILE" 2>/dev/null && return 0
    [[ -d "$PATHS_D" ]] || return 1
    grep -qxF "$PREFIX" "$PATHS_D"/* 2>/dev/null
}

check_platform() {
    [[ "$(uname -s)" == "Darwin" ]] || die "$BINARY_NAME only runs on macOS"
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= MIN_MACOS_MAJOR )) || die "macOS $MIN_MACOS_MAJOR or later is required (found $(sw_vers -productVersion))"
    command -v swift >/dev/null 2>&1 || die "swift not found; install Xcode or the Xcode Command Line Tools"
}

build() {
    if (( SKIP_BUILD )); then
        info "Skipping build"
    else
        info "Building $BINARY_NAME (release)"
        run_as_invoking_user swift build -c release --package-path "$ROOT" --product "$BINARY_NAME"
    fi
    local bin_dir
    bin_dir="$(run_as_invoking_user swift build -c release --package-path "$ROOT" --show-bin-path)"
    BUILT_BINARY="$bin_dir/$BINARY_NAME"
    [[ -x "$BUILT_BINARY" ]] || die "no release build at $BUILT_BINARY (run without --skip-build)"
}

install_binary() {
    info "Installing to $TARGET"
    as_owner "$PREFIX" mkdir -p "$PREFIX"
    if [[ -w "$PREFIX" ]]; then
        install -m 0755 "$BUILT_BINARY" "$TARGET"
    else
        sudo install -o root -g wheel -m 0755 "$BUILT_BINARY" "$TARGET"
    fi
}

register_path() {
    (( CONFIGURE_PATH )) || return 0
    if path_registered; then
        info "$PREFIX is already on the system PATH"
        return 0
    fi
    info "Adding $PREFIX to the PATH of every user ($PATHS_ENTRY)"
    as_owner "$PATHS_D" mkdir -p "$PATHS_D"
    printf '%s\n' "$PREFIX" | as_owner "$PATHS_D" tee "$PATHS_ENTRY" >/dev/null
    PATH_CHANGED=1
}

verify() {
    local version
    version="$("$TARGET" --version)" || die "installed binary failed to run: $TARGET"
    info "Installed $BINARY_NAME $version"
    if ! command -v ffmpeg >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/ffmpeg && ! -x /usr/local/bin/ffmpeg ]]; then
        warn "ffmpeg not found; $BINARY_NAME needs it for info/play/cast. Install it with: brew install ffmpeg"
    fi
    if [[ "${PATH_CHANGED:-0}" == 1 ]]; then
        info "Open a new terminal (or run: eval \"\$(/usr/libexec/path_helper -s)\") to pick up the PATH change"
    fi
}

uninstall() {
    if [[ -e "$TARGET" ]]; then
        info "Removing $TARGET"
        as_owner "$PREFIX" rm -f "$TARGET"
    else
        info "$TARGET is not installed"
    fi
    if [[ -f "$PATHS_ENTRY" ]] && grep -qxF "$PREFIX" "$PATHS_ENTRY"; then
        info "Removing $PATHS_ENTRY"
        as_owner "$PATHS_D" rm -f "$PATHS_ENTRY"
    fi
    info "Pairing credentials stay in the login Keychain (service com.airstar.cli.pairing); use 'airstar-cli pair <tv> --forget' first to remove them"
}

case "$ACTION" in
    install)
        check_platform
        build
        install_binary
        register_path
        verify
        ;;
    uninstall)
        uninstall
        ;;
esac
