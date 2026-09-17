#!/usr/bin/env bash
#
# Build the dReal Python binding (the `dreal` module) with the pinned Bazel,
# against the IBEX built by scripts/build_ibex.sh.
#
# This produces the three shared objects that scripts/install_binding.sh stages
# into a Python installation. It does not install anything.
#
# Usage: scripts/build_binding.sh [-j N] [--python /path/to/python3.11] [-- bazel args...]

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    --python) BINDING_PYTHON="$2"; shift 2 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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
setup_bazel_flags
setup_binding_python

# setup_binding_python resolves an interpreter of the right series but does not
# ask whether it can serve the build. This is the one place that matters: the
# binding gets its include path from dReal's vendored python_configure repository
# rule, which runs 'from distutils import sysconfig' through the interpreter named
# in PYTHON_BIN_PATH. Python 3.12 removed distutils, so an interpreter that
# cannot answer it aborts the build during analysis, before anything is compiled.
_bazel_python_ok "$BINDING_PYTHON" || die "$BINDING_PYTHON cannot answer dReal's
python_configure query:

  $BINDING_PYTHON -c 'from distutils import sysconfig; print(sysconfig.get_python_inc())'

That rule needs the interpreter's include directory to compile the binding, and
distutils was removed in Python 3.12. This usually means the interpreter is a
3.11 whose distutils has been stripped, or one whose setuptools does not provide
the shim. Name another with BINDING_PYTHON=/path/to/python$BINDING_PYTHON_SERIES."

[ -f "$IBEX_INSTALL/share/pkgconfig/ibex.pc" ] \
  || die "IBEX is not built yet. Run scripts/build_ibex.sh first."

LOG="$BUILD_ROOT/build-binding.log"
log "building the dReal $DREAL_VERSION Python binding with Bazel $BAZEL_VERSION"
log "log $LOG"

fetch_verified "$DREAL_URL" "$DREAL_SHA256" "$BUILD_SRC/$DREAL_TARBALL"
prepare_source "$BUILD_SRC/$DREAL_TARBALL" "$DREAL_SRCDIR" \
               "$DREAL_MACOS15_ROOT/patches/dreal" "dreal"

cd "$DREAL_SRC"

log "bazel shutdown (drop any stale client environment)"
"$BAZELISK" shutdown >/dev/null 2>&1 || true

# Same flags as the CLI build (setup_bazel_flags documents them), with this
# build's interpreter in place of the CLI's. PYTHON_BIN_PATH is what reaches
# dReal's vendored python_configure repository rule, and it is the reason the
# binding is compiled against one interpreter series and no other: the rule
# hands the compile actions that interpreter's headers, and the resulting .so
# is loaded by an interpreter of the same series or by nothing at all.
#
# -DDREAL_CHECK_INTERRUPT is upstream's choice for this target alone (setup.py
# passes it and nothing else does): it turns the solver's inner loops into
# SIGINT checks that raise instead of running to completion, which is what makes
# Ctrl-C work in a Python session. It is a source-level define, so it changes the
# configuration and this build's libdreal.so is not the byte-for-byte twin of the
# CLI's; that is intended, and the two never meet in one process.
bazel_args=(
  build
  "${BAZEL_COMMON_FLAGS[@]}"
  --repo_env=PYTHON_BIN_PATH="$BINDING_PYTHON"
  --cxxopt=-DDREAL_CHECK_INTERRUPT
  --jobs="$JOBS"
  --noshow_progress
)
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  bazel_args+=("${EXTRA_ARGS[@]}")
fi
bazel_args+=(
  //dreal:_dreal_py.so
  //dreal:_odr_test_module_py.so
  //:libdreal.so
)

log "building the binding modules and libdreal.so"
set -o pipefail
CC="$CC" \
CXX="$CXX" \
"$BAZELISK" "${bazel_args[@]}" 2>&1 | tee "$LOG"

# --------------------------------------------------------------- verify ---
MODULE="$DREAL_SRC/bazel-bin/dreal/_dreal_py.so"
ODR_MODULE="$DREAL_SRC/bazel-bin/dreal/_odr_test_module_py.so"
LIBDREAL="$DREAL_SRC/bazel-bin/libdreal.so"

for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  [ -f "$f" ] || die "build produced no $(basename "$f") at $f"
  file "$f" | grep -q 'arm64' \
    || die "$(basename "$f") is not arm64: $(file "$f")"
done
ok "built _dreal_py.so, _odr_test_module_py.so, libdreal.so (arm64)"

# The extension is compiled by the GCC shim, so it must record libstdc++. If it
# records libc++ the shim was bypassed and the module would be built against a
# different C++ runtime than the libdreal.so it loads -- the failure mode being
# unresolved symbols at import, far from the cause.
if ! otool -L "$MODULE" | grep -q 'libstdc++'; then
  die "$(basename "$MODULE") does not link libstdc++.

The binding must use the same C++ runtime as the GCC-built IBEX. CC must be
scripts/toolchain/cc-wrapper.sh (scripts/lib/common.sh:setup_gcc sets it)."
fi
ok "_dreal_py.so links libstdc++"

if ! otool -L "$MODULE" | grep -q 'libdreal'; then
  die "$(basename "$MODULE") does not link libdreal.so.

The pybind module deliberately compiles none of dReal itself: it declares a
dependency on //:libdreal.so (tools/dreal.bzl:dreal_pybind_library) so that the
symbolic layer exists once per process. See dreal/test/python/odr_test.py."
fi
ok "_dreal_py.so links libdreal -> $(otool -L "$MODULE" | awk '/libdreal/{print $1; exit}')"

# Record what this binding was built against, next to the sources it came from.
# scripts/install_binding.sh copies the file into the staged package, so the
# interpreter is discoverable from an installed tree alone.
{
  echo "binding_python     $BINDING_PYTHON"
  echo "binding_python_version $("$BINDING_PYTHON" -c 'import sys; print(sys.version.split()[0])')"
  echo "ext_suffix         $("$BINDING_PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or "")')"
  echo "pybind11_version   $PYBIND11_VERSION"
  echo "build_date_utc     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUILD_ROOT/binding-info"
ok "wrote binding-info"

log "binding built: $MODULE"
