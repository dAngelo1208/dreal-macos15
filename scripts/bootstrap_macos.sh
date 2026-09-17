#!/usr/bin/env bash
#
# Verify the host, install Homebrew dependencies, and download the pinned
# upstream sources. Idempotent; safe to re-run.
#
# Usage: scripts/bootstrap_macos.sh [--skip-brew]

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SKIP_BREW=0
for arg in "$@"; do
  case "$arg" in
    --skip-brew) SKIP_BREW=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

log "dReal for macOS 15+ (Apple Silicon) v0.1 -- bootstrap"

# ----------------------------------------------------------- host checks ---
require_apple_silicon
require_macos_version 15

xcode-select -p >/dev/null 2>&1 \
  || die "Xcode Command Line Tools not installed.

Run:  xcode-select --install"
ok "Command Line Tools at $(xcode-select -p)"

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
  || die "Python 3.8+ required on PATH"

# ------------------------------------------------------------- packages ----
setup_homebrew
if [ "$SKIP_BREW" -eq 0 ]; then
  log "installing Homebrew dependencies from Brewfile"
  # `brew bundle` is idempotent: already-satisfied formulae are skipped.
  brew bundle --file="$DREAL_MACOS15_ROOT/Brewfile" \
    || die "brew bundle failed; see Brewfile and docs/macos.md"
else
  log "skipping Homebrew installs (--skip-brew)"
fi

for f in bison flex gmp nlopt clp coinutils pkgconf gcc bazelisk python@3.10; do
  brew list --formula "$f" >/dev/null 2>&1 || die "missing Homebrew formula: $f"
done
ok "Homebrew dependencies present"

# ------------------------------------------------------------ toolchain ----
# These export CC/CXX/PKG_CONFIG/BISON/IBEX_PYTHON for the rest of this script
# and for the build scripts when sourced from the same shell.
setup_gcc
setup_bison_flex
setup_pkg_config
setup_ibex_python

# -------------------------------------------------------------- sources ----
setup_build_root
log "build root $BUILD_ROOT"
fetch_verified "$DREAL_URL" "$DREAL_SHA256" "$BUILD_SRC/$DREAL_TARBALL"
fetch_verified "$IBEX_URL"  "$IBEX_SHA256"  "$BUILD_SRC/$IBEX_TARBALL"

# Resolving Bazel downloads the pinned release on first use.
setup_bazel

log "bootstrap complete"
cat <<EOF

Next:
  scripts/build_ibex.sh      # IBEX $IBEX_VERSION, direct interval library
  scripts/build_dreal.sh     # dReal $DREAL_VERSION
  scripts/install_macos.sh   # install to $BREW_PREFIX/$INSTALL_ROOT_BASENAME
  tests/test_binary.sh       # acceptance tests

Or in one step:  make all

EOF
