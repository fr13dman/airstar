#!/usr/bin/env bash
# Tests install.sh against a temporary prefix and a fake /etc/paths(.d), so it needs no root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/airstar-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export AIRSTAR_PATHS_FILE="$WORK/etc/paths"
export AIRSTAR_PATHS_D="$WORK/etc/paths.d"
mkdir -p "$WORK/etc"
printf '/usr/local/bin\n/usr/bin\n/bin\n' > "$AIRSTAR_PATHS_FILE"

PREFIX="$WORK/sbin"
FAILURES=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# 1. Fresh install builds, copies an executable binary and registers the PATH entry.
"$INSTALLER" --prefix "$PREFIX" > "$WORK/install.log" 2>&1 || { cat "$WORK/install.log"; fail "install exits 0"; }
check "binary installed and executable" test -x "$PREFIX/airstar-cli"
check "binary runs from the install location" bash -c "'$PREFIX/airstar-cli' --version | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'"
check "help lists the cast command" bash -c "'$PREFIX/airstar-cli' --help | grep -q 'cast'"
check "PATH entry written to paths.d" grep -qxF "$PREFIX" "$AIRSTAR_PATHS_D/airstar-cli"
check "permissions are 755" bash -c "[[ \$(stat -f '%Lp' '$PREFIX/airstar-cli') == 755 ]]"

# 2. Reinstalling is idempotent and does not duplicate the PATH entry.
"$INSTALLER" --prefix "$PREFIX" --skip-build > "$WORK/reinstall.log" 2>&1 || fail "reinstall exits 0"
check "reinstall reports PATH already registered" grep -q "already on the system PATH" "$WORK/reinstall.log"
check "PATH entry not duplicated" bash -c "[[ \$(grep -cxF '$PREFIX' '$AIRSTAR_PATHS_D/airstar-cli') == 1 ]]"

# 3. A prefix already listed in /etc/paths needs no paths.d entry.
OTHER="$WORK/bin"
printf '%s\n' "$OTHER" >> "$AIRSTAR_PATHS_FILE"
"$INSTALLER" --prefix "$OTHER" --skip-build > "$WORK/other.log" 2>&1 || fail "install to listed prefix exits 0"
check "listed prefix skips registration" grep -q "already on the system PATH" "$WORK/other.log"

# 4. --no-path leaves paths.d alone.
NOPATH="$WORK/nopath"
"$INSTALLER" --prefix "$NOPATH" --skip-build --no-path > /dev/null 2>&1 || fail "--no-path install exits 0"
check "--no-path installs the binary" test -x "$NOPATH/airstar-cli"
check "--no-path does not register" bash -c "! grep -rqxF '$NOPATH' '$AIRSTAR_PATHS_D'"

# 5. Uninstall removes the binary and its PATH entry.
"$INSTALLER" --prefix "$PREFIX" --uninstall > /dev/null 2>&1 || fail "uninstall exits 0"
check "uninstall removes the binary" test ! -e "$PREFIX/airstar-cli"
check "uninstall removes the PATH entry" test ! -e "$AIRSTAR_PATHS_D/airstar-cli"
"$INSTALLER" --prefix "$PREFIX" --uninstall > "$WORK/uninstall2.log" 2>&1 || fail "second uninstall exits 0"
check "uninstall is idempotent" grep -q "is not installed" "$WORK/uninstall2.log"

# 6. Bad arguments are rejected.
check "unknown option fails" bash -c "! '$INSTALLER' --bogus > /dev/null 2>&1"
check "relative prefix fails" bash -c "! '$INSTALLER' --prefix relative/dir --skip-build > /dev/null 2>&1"
check "--help succeeds" bash -c "'$INSTALLER' --help | grep -q 'Usage'"

if (( FAILURES > 0 )); then
    printf '\n%d check(s) failed\n' "$FAILURES"
    exit 1
fi
printf '\nall install checks passed\n'
