#!/usr/bin/env bash
#
# Build the pinned IBEX from source for Apple Silicon.
#
# IBEX is built with the Homebrew GCC toolchain so that it links libstdc++, the
# same runtime dReal is built against. The upstream Intel assumptions that this
# step removes are documented in patches/ibex/.
#
# Usage: scripts/build_ibex.sh [-j N]

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_apple_silicon
setup_homebrew
setup_gcc
setup_bison_flex
setup_pkg_config
setup_ibex_python
setup_build_root
setup_pkg_config_path

LOG="$BUILD_ROOT/build-ibex.log"
log "building IBEX $IBEX_VERSION ($IBEX_COMMIT)"
log "log $LOG"

fetch_verified "$IBEX_URL" "$IBEX_SHA256" "$BUILD_SRC/$IBEX_TARBALL"
prepare_source "$BUILD_SRC/$IBEX_TARBALL" "$IBEX_SRCDIR" \
               "$DREAL_MACOS15_ROOT/patches/ibex" "ibex"

cd "$IBEX_SRC"

# Start from a clean configuration: waf caches the configured toolchain under
# .waf3-*/ and writes its objects to __build__/, and a stale cache silently
# reuses the previous compiler and options.
rm -rf "$IBEX_SRC/.waf3-"* "$IBEX_SRC/__build__" 2>/dev/null || true

# --interval-lib=direct : no SSE/AVX intrinsics, so the build does not depend on
#                         x86 vector units and behaves identically on arm64.
# --lp-lib=clp          : the LP backend dReal expects.
# --enable-shared       : dReal links libibex dynamically.
log "waf configure"
{
  "$IBEX_PYTHON" ./waf configure \
    --prefix="$IBEX_INSTALL" \
    --enable-shared \
    --interval-lib=direct \
    --lp-lib=clp
} 2>&1 | tee "$LOG"

grep -q "configure' finished successfully" "$LOG" \
  || die "waf configure did not complete; see $LOG"

log "waf build -j $JOBS"
"$IBEX_PYTHON" ./waf build -j "$JOBS" 2>&1 | tee -a "$LOG"

log "waf install -> $IBEX_INSTALL"
"$IBEX_PYTHON" ./waf install 2>&1 | tee -a "$LOG"

# --------------------------------------------------------------- verify ---
[ -f "$IBEX_INSTALL/lib/libibex.dylib" ] \
  || die "libibex.dylib was not installed to $IBEX_INSTALL/lib"
ok "libibex.dylib"

PC="$IBEX_INSTALL/share/pkgconfig/ibex.pc"
[ -f "$PC" ] || die "ibex.pc not installed to $IBEX_INSTALL/share/pkgconfig"

# Guard against reintroducing the x86-only flag. patches/ibex/0002 removes it at
# the source, so this must never fire; if it does, a patch has been lost.
if grep -q -- '-msse3' "$PC"; then
  die "$PC still carries -msse3.

patches/ibex/0002-ibex-pc-in-drop-msse3.patch should have removed it at the
source. Do not paper over this with sed on the generated file -- fix the patch."
fi
if grep -q -- '-msse' "$PC"; then
  die "$PC still carries an SSE flag: $(grep -- '-msse' "$PC")"
fi
ok "ibex.pc carries no x86-only SIMD flags"

if command -v otool >/dev/null 2>&1; then
  if otool -L "$IBEX_INSTALL/lib/libibex.dylib" | grep -q 'libstdc++'; then
    ok "libibex links libstdc++ (matches the GCC toolchain)"
  else
    die "libibex does not link libstdc++; the C++ runtime would not match dReal.

Expected a Homebrew GCC build. Check that CC/CXX point at \$(brew --prefix gcc)."
  fi
fi

log "IBEX built: $IBEX_INSTALL"
