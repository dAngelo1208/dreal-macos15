#!/usr/bin/env bash
#
# Install the built dReal CLI and IBEX runtime into a stable prefix and wire up
# /opt/homebrew/bin/dreal.
#
# After this step the installed artefacts must not reference the build root,
# the Bazel output base, or the Bazel external cache.
#
# Usage: scripts/install_macos.sh [--prefix DIR] [--no-link]

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

NO_LINK=0
PREFIX_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX_OVERRIDE="$2"; shift 2 ;;
    --no-link) NO_LINK=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_apple_silicon
setup_homebrew
setup_gcc
setup_pkg_config
setup_build_root
# Not used to build anything here, but BUILD-INFO records which interpreter the
# Bazel build needed -- knowing it later is the difference between "this failed
# on a machine with a new Python" and "we have no idea what it used".
setup_bazel_python

INSTALL_ROOT="${PREFIX_OVERRIDE:-$BREW_PREFIX/$INSTALL_ROOT_BASENAME}"
BIN_SRC="$DREAL_SRC/bazel-bin/dreal/dreal"
LIB_SRC="$IBEX_INSTALL/lib/libibex.dylib"

[ -x "$BIN_SRC" ] || die "no built binary at $BIN_SRC; run scripts/build_dreal.sh"
[ -f "$LIB_SRC" ] || die "no built library at $LIB_SRC; run scripts/build_ibex.sh"

log "installing into $INSTALL_ROOT"
install -d "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib"

install -m 755 "$BIN_SRC" "$INSTALL_ROOT/bin/dreal"
install -m 755 "$LIB_SRC" "$INSTALL_ROOT/lib/libibex.dylib"

INSTALLED_LIB="$INSTALL_ROOT/lib/libibex.dylib"
INSTALLED_BIN="$INSTALL_ROOT/bin/dreal"

# ---------------------------------------------------- install names -------
# The dylib's own install name currently points into $IBEX_INSTALL, and dreal
# records that same path as its dependency. Rewrite both to the final prefix so
# the pair is self-contained and does not depend on where it was built.
install_name_tool -id "$INSTALLED_LIB" "$INSTALLED_LIB"

OLD_IBEX_PATH="$(otool -L "$INSTALLED_BIN" | awk '/\/libibex\.dylib/ {print $1; exit}')"
[ -n "$OLD_IBEX_PATH" ] || die "could not determine the libibex install name in $INSTALLED_BIN"
install_name_tool -change "$OLD_IBEX_PATH" "$INSTALLED_LIB" "$INSTALLED_BIN"
ok "libibex: $OLD_IBEX_PATH -> $INSTALLED_LIB"

# On Apple Silicon every Mach-O must carry a valid signature, and
# install_name_tool invalidates the existing one. Without this the binary is
# killed by the kernel on first exec.
for f in "$INSTALLED_BIN" "$INSTALLED_LIB"; do
  codesign --force --sign - "$f" >/dev/null 2>&1 \
    || warn "codesign failed for $f; it may not run on Apple Silicon"
done
ok "re-signed (ad-hoc)"

# ------------------------------------------------------------ verify ------
# Anything left pointing at the build root, the Bazel output tree or a temp
# directory would make the install depend on this machine's caches.
TMP_PATTERNS="$BUILD_ROOT|/bazel-|execroot|/\.cache/bazel|/var/folders/|/tmp/"
for f in "$INSTALLED_BIN" "$INSTALLED_LIB"; do
  if otool -L "$f" | tail -n +2 | grep -Eq "$TMP_PATTERNS"; then
    otool -L "$f" | tail -n +2 | grep -E "$TMP_PATTERNS" >&2
    die "$f depends on a build or cache directory (above); the install is not portable."
  fi
done
ok "no build-root or cache references in otool -L"

file "$INSTALLED_BIN" | grep -q 'arm64' \
  || die "$INSTALLED_BIN is not an arm64 executable: $(file "$INSTALLED_BIN")"
ok "$(file "$INSTALLED_BIN" | sed 's/^[^:]*: //')"

write_build_info "$INSTALL_ROOT/BUILD-INFO"

# --------------------------------------------------------------- link -----
if [ "$NO_LINK" -eq 0 ]; then
  LINK="$BREW_PREFIX/bin/dreal"
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    warn "$LINK exists and is not a symlink; leaving it alone"
  else
    ln -sf "$INSTALLED_BIN" "$LINK"
    ok "linked $LINK -> $INSTALLED_BIN"
  fi
fi

log "installed"
"$INSTALLED_BIN" --version
