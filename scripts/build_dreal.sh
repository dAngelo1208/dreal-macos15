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
setup_bazel_python

[ -f "$IBEX_INSTALL/share/pkgconfig/ibex.pc" ] \
  || die "IBEX is not built yet. Run scripts/build_ibex.sh first."

LOG="$BUILD_ROOT/build-dreal.log"
log "building dReal $DREAL_VERSION with Bazel $BAZEL_VERSION"
log "log $LOG"

fetch_verified "$DREAL_URL" "$DREAL_SHA256" "$BUILD_SRC/$DREAL_TARBALL"
prepare_source "$BUILD_SRC/$DREAL_TARBALL" "$DREAL_SRCDIR" \
               "$DREAL_MACOS15_ROOT/patches/dreal" "dreal"

cd "$DREAL_SRC"

setup_bazel_flags

# Bazel's server holds a snapshot of the client environment from when it
# started. A long-lived server would otherwise reuse a stale PKG_CONFIG_PATH
# from an earlier run, so the repository rules would silently resolve against
# the wrong IBEX. Shutting down between builds makes every run independent of
# whatever the daemon happens to remember.
log "bazel shutdown (drop any stale client environment)"
"$BAZELISK" shutdown >/dev/null 2>&1 || true

# The flags shared by every build in this repository -- the GCC shim, the
# pkg-config paths, BAZEL_USE_CPP_ONLY_TOOLCHAIN -- come from setup_bazel_flags
# (scripts/lib/common.sh), which documents what each one is for. Only the
# interpreter is per-build.
#
# PYTHON_BIN_PATH is read by the vendored TensorFlow python_configure repository
# rule, which otherwise falls back to whatever `python3` is on PATH -- and a
# Python 3.12+ interpreter has no distutils, so the fetch fails and the build
# dies during analysis. setup_bazel_python probes for one that still works and
# pins it here. It is a repository env because repository rules see the declared
# client environment, not the sandbox's; for the same reason the CLI build passes
# it here and the binding build passes setup_binding_python's in its place.
#
# `-- args...` appends to the Bazel command line. It is how a one-off flag is used
# without editing this script; it is appended after this script's own options, so
# a flag that also appears above is overridden by the one given here.
bazel_args=(
  build
  "${BAZEL_COMMON_FLAGS[@]}"
  --repo_env=PYTHON_BIN_PATH="$BAZEL_PYTHON"
  --jobs="$JOBS"
  --noshow_progress
)
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  bazel_args+=("${EXTRA_ARGS[@]}")
fi
bazel_args+=(//dreal:dreal)

log "building //dreal:dreal"
set -o pipefail
CC="$CC" \
CXX="$CXX" \
"$BAZELISK" "${bazel_args[@]}" 2>&1 | tee "$LOG"

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
