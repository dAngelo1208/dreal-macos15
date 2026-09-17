#!/usr/bin/env bash
#
# Build the pinned dReal CLI with the pinned Bazel, against the IBEX built by
# scripts/build_ibex.sh.
#
# Usage: scripts/build_dreal.sh [-j N] [-- bazel args...]

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_apple_silicon
setup_homebrew
setup_gcc
setup_bison_flex
setup_pkg_config
setup_build_root
setup_pkg_config_path
setup_bazel

[ -f "$IBEX_INSTALL/share/pkgconfig/ibex.pc" ] \
  || die "IBEX is not built yet. Run scripts/build_ibex.sh first."

LOG="$BUILD_ROOT/build-dreal.log"
log "building dReal $DREAL_VERSION with Bazel $BAZEL_VERSION"
log "log $LOG"

fetch_verified "$DREAL_URL" "$DREAL_SHA256" "$BUILD_SRC/$DREAL_TARBALL"
prepare_source "$BUILD_SRC/$DREAL_TARBALL" "$DREAL_SRCDIR" \
               "$DREAL_MACOS15_ROOT/patches/dreal" "dreal"

cd "$DREAL_SRC"

GMP_PREFIX="$(brew --prefix gmp)"

# Bazel's server holds a snapshot of the client environment from when it
# started. A long-lived server would otherwise reuse a stale PKG_CONFIG_PATH
# from an earlier run, so the repository rules would silently resolve against
# the wrong IBEX. Shutting down between builds makes every run independent of
# whatever the daemon happens to remember.
log "bazel shutdown (drop any stale client environment)"
"$BAZELISK" shutdown >/dev/null 2>&1 || true

# CC is the shim from scripts/lib/common.sh: it rewrites the `-lc++` that
# Bazel's Darwin toolchain hardcodes on every C++ link line into `-lstdc++`, so
# the binary links the same C++ runtime as the GCC-built IBEX. DREAL_REAL_CC has
# to be passed as an action env as well as a repo env: the compile and link
# actions run in a sandbox with a stripped environment, and the repository rule
# that identifies the compiler runs in the client environment. Neither would see
# it otherwise.
log "building //dreal:dreal"
set -o pipefail
CC="$CC" \
CXX="$CXX" \
"$BAZELISK" build \
  --config=macos_arm64 \
  --jobs="$JOBS" \
  --noshow_progress \
  --repo_env=PKG_CONFIG \
  --repo_env=PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
  --repo_env=HOMEBREW_PREFIX="$BREW_PREFIX" \
  --repo_env=GMP_PREFIX="$GMP_PREFIX" \
  --repo_env=CC="$CC" \
  --repo_env=CXX="$CXX" \
  --repo_env=DREAL_REAL_CC="$DREAL_REAL_CC" \
  --action_env=DREAL_REAL_CC="$DREAL_REAL_CC" \
  --repo_env=BISON="$BISON" \
  --repo_env=PATH \
  //dreal:dreal 2>&1 | tee "$LOG"

BIN="$DREAL_SRC/bazel-bin/dreal/dreal"
[ -x "$BIN" ] || die "build produced no binary at $BIN"

# --------------------------------------------------------------- verify ---
if ! otool -L "$BIN" | grep -q 'libstdc++'; then
  die "$BIN does not link libstdc++.

dReal must use the same C++ runtime as the GCC-built IBEX. CC must be
scripts/toolchain/cc-wrapper.sh (scripts/lib/common.sh:setup_gcc sets it), and
DREAL_REAL_CC must reach the link action as an --action_env."
fi
ok "dreal links libstdc++"

if ! otool -L "$BIN" | grep -q 'libibex'; then
  die "$BIN does not link libibex.

pkg-config did not find ibex.pc. Check that PKG_CONFIG_PATH contains
$IBEX_INSTALL/share/pkgconfig (see scripts/lib/common.sh)."
fi
ok "dreal links libibex -> $(otool -L "$BIN" | awk '/libibex/{print $1; exit}')"

"$BIN" --version >/dev/null 2>&1 || die "$BIN failed to run"
ok "dreal --version runs"

log "dReal built: $BIN"
