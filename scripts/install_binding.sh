#!/usr/bin/env bash
#
# Install the built dReal Python binding into a Python installation, and fix up
# the install names of the shared objects it is made of.
#
# The package is installed as `dreal`, holding upstream's `__init__.py` and the
# three Mach-O files the binding is made of. Nothing here needs a build-time
# environment afterwards: no PKG_CONFIG_PATH, no CC/CXX, no BUILD_ROOT.
#
# libibex.dylib is *not* copied. The staged shared objects point at the one in
# the dReal install ($INSTALL_ROOT/lib), so the CLI and the binding resolve the
# same IBEX -- one C++ runtime, one IBEX, one libstdc++, whether the entry point
# is the dreal binary or `import dreal`. Run scripts/install_macos.sh first.
#
# Usage: scripts/install_binding.sh [--dest DIR] [--site-packages]
#                                  [--python /path/to/python3.11] [--prefix DIR]

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DEST_OVERRIDE=""
USE_SITE_PACKAGES=0
PREFIX_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST_OVERRIDE="$2"; shift 2 ;;
    --site-packages) USE_SITE_PACKAGES=1; shift ;;
    --python) BINDING_PYTHON="$2"; shift 2 ;;
    --prefix) PREFIX_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$DEST_OVERRIDE" ] && [ "$USE_SITE_PACKAGES" -eq 1 ] \
  && die "--dest and --site-packages are mutually exclusive"

require_apple_silicon
setup_homebrew
setup_build_root
setup_binding_python

INSTALL_ROOT="${PREFIX_OVERRIDE:-$BREW_PREFIX/$INSTALL_ROOT_BASENAME}"
IBEX_LIB="$INSTALL_ROOT/lib/libibex.dylib"

MODULE_SRC="$DREAL_SRC/bazel-bin/dreal/_dreal_py.so"
ODR_MODULE_SRC="$DREAL_SRC/bazel-bin/dreal/_odr_test_module_py.so"
LIBDREAL_SRC="$DREAL_SRC/bazel-bin/libdreal.so"
INIT_SRC="$DREAL_SRC/dreal/__init__.py"

[ -f "$MODULE_SRC" ] && [ -f "$ODR_MODULE_SRC" ] && [ -f "$LIBDREAL_SRC" ] \
  || die "no built binding at $MODULE_SRC; run scripts/build_binding.sh"
[ -f "$IBEX_LIB" ] || die "no installed IBEX at $IBEX_LIB; run scripts/install_macos.sh"

# The extension is ABI-locked to one interpreter series, so the interpreter it is
# installed for has to be one of that series -- a 3.10 or 3.12 interpreter would
# fail at import with a confusing "incompatible architecture" or symbol error.
GOT_SERIES="$("$BINDING_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
[ "$GOT_SERIES" = "$BINDING_PYTHON_SERIES" ] || die "the binding is built for Python
$BINDING_PYTHON_SERIES and cannot be loaded by Python $GOT_SERIES ($BINDING_PYTHON).

Pass the interpreter to install for with --python, e.g.
  scripts/install_binding.sh --python /path/to/python$BINDING_PYTHON_SERIES"

if [ -n "$DEST_OVERRIDE" ]; then
  DEST="$DEST_OVERRIDE"
elif [ "$USE_SITE_PACKAGES" -eq 1 ]; then
  # Ask the interpreter rather than reconstructing the path: a conda environment
  # and a Homebrew framework build do not agree on the layout.
  DEST="$("$BINDING_PYTHON" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
else
  # Default: a self-contained location under the dReal install, next to the CLI
  # that shares its libibex. It is not on any interpreter's path, so the last
  # lines of this script print how to reach it.
  DEST="$INSTALL_ROOT/lib/python$BINDING_PYTHON_SERIES/site-packages"
fi
PKG_DIR="$DEST/dreal"

log "installing the dReal $DREAL_VERSION Python binding for $BINDING_PYTHON"
log "into $PKG_DIR"

mkdir -p "$PKG_DIR"
install -m 644 "$INIT_SRC" "$PKG_DIR/__init__.py"
install -m 755 "$MODULE_SRC" "$PKG_DIR/_dreal_py.so"
install -m 755 "$ODR_MODULE_SRC" "$PKG_DIR/_odr_test_module_py.so"
install -m 755 "$LIBDREAL_SRC" "$PKG_DIR/libdreal.so"

# --------------------------------------------------------- install names ----
# Four Mach-O files, five references. As built, each records its dependency by a
# path into the Bazel output tree, and the entry points record their own name as
# that same build path; neither survives the copy. Each file's id is set to where
# it really is, and the references *between* the four use @loader_path, so the
# package works wherever it is installed. The one reference that stays absolute
# is libibex.dylib, precisely so that it is the CLI's copy.
for f in "$PKG_DIR/_dreal_py.so" "$PKG_DIR/_odr_test_module_py.so" "$PKG_DIR/libdreal.so"; do
  install_name_tool -id "$f" "$f"
done

# The two pybind modules record libdreal.so the same way; libdreal.so records
# libibex. Retarget each to its sibling, or to the install's IBEX.
for f in "$PKG_DIR/_dreal_py.so" "$PKG_DIR/_odr_test_module_py.so"; do
  old="$(otool -L "$f" | awk '/libdreal/{print $1; exit}')"
  [ -n "$old" ] || die "no libdreal reference found in $(basename "$f")"
  install_name_tool -change "$old" "@loader_path/libdreal.so" "$f"
  ok "$(basename "$f"): libdreal -> @loader_path/libdreal.so"
done

# All three record libibex by a path into the IBEX build tree -- libdreal.so
# because it is built against IBEX, and the two modules because they link it
# directly to resolve the inline IBEX code the symbolic headers use. Retargeting
# all three at the install's copy is what keeps the CLI and the binding on one
# IBEX rather than two that merely happen to have the same version.
for f in "$PKG_DIR/_dreal_py.so" "$PKG_DIR/_odr_test_module_py.so" "$PKG_DIR/libdreal.so"; do
  old="$(otool -L "$f" | awk '/libibex/{print $1; exit}')"
  [ -n "$old" ] || die "no libibex reference found in $(basename "$f")"
  install_name_tool -change "$old" "$IBEX_LIB" "$f"
  ok "$(basename "$f"): libibex -> $IBEX_LIB"
done

# On Apple Silicon every Mach-O must carry a valid signature, and
# install_name_tool invalidates the existing one. Without this the modules fail
# to load with an unhelpful dlopen error.
for f in "$PKG_DIR/_dreal_py.so" "$PKG_DIR/_odr_test_module_py.so" "$PKG_DIR/libdreal.so"; do
  codesign --force --sign - "$f" >/dev/null 2>&1 \
    || warn "codesign failed for $(basename "$f"); it may not load on Apple Silicon"
done
ok "re-signed (ad-hoc)"

# --------------------------------------------------------------- verify ----
# Anything left pointing at the build root, the Bazel output tree or a temp
# directory would make the install depend on this machine's caches.
TMP_PATTERNS="$BUILD_ROOT|/bazel-|execroot|/\.cache/bazel|/var/folders/|/tmp/"
for f in "$PKG_DIR/_dreal_py.so" "$PKG_DIR/_odr_test_module_py.so" "$PKG_DIR/libdreal.so"; do
  if otool -L "$f" | tail -n +2 | grep -Eq "$TMP_PATTERNS"; then
    otool -L "$f" | tail -n +2 | grep -E "$TMP_PATTERNS" >&2
    die "$f depends on a build or cache directory (above); the install is not portable."
  fi
done
ok "no build-root or Bazel-cache references in otool -L"

# Every non-system dependency must resolve to a file that exists right now, and
# every @loader_path dependency must land inside the package that will load it.
UNRESOLVED=""
while IFS= read -r dep; do
  case "$dep" in
    /usr/lib/*|/System/*) continue ;;
  esac
  [ -e "$dep" ] || UNRESOLVED="$UNRESOLVED$dep"$'\n'
done < <(for f in "$PKG_DIR/_dreal_py.so" "$PKG_DIR/_odr_test_module_py.so" "$PKG_DIR/libdreal.so"; do
           otool -L "$f" | tail -n +2 | awk '{print $1}'
         done | grep -v '^@loader_path/' | sort -u)
if [ -z "$UNRESOLVED" ]; then
  ok "all non-system dependencies resolve"
else
  die "unresolved dependencies:
$UNRESOLVED"
fi

"$BINDING_PYTHON" -c 'import sys' >/dev/null || die "$BINDING_PYTHON does not run"
SMOKE="$(PYTHONPATH="$DEST" "$BINDING_PYTHON" -c 'import dreal; print(dreal.__version__)' 2>&1)" \
  || die "import dreal failed with PYTHONPATH=$DEST:

$SMOKE"
# dreal/__init__.py computes __version__ as "4.21.06.2".replace(".0", "."), so
# the module reports 4.21.6.2 where the CLI reports the raw tag 4.21.06.2.
EXPECTED_VERSION="$(printf '%s' "$DREAL_VERSION" | sed 's/\.0/./')"
[ "$SMOKE" = "$EXPECTED_VERSION" ] || die "import dreal reported version '$SMOKE',
expected '$EXPECTED_VERSION'"
ok "import dreal -> $SMOKE"

# ------------------------------------------------------------- record ------
{
  echo "dreal_version      $DREAL_VERSION"
  echo "binding_python     $BINDING_PYTHON"
  echo "binding_python_version $("$BINDING_PYTHON" -c 'import sys; print(sys.version.split()[0])')"
  echo "pybind11_version   $PYBIND11_VERSION"
  echo "ext_suffix         $("$BINDING_PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or "")')"
  echo "site_packages      $DEST"
  echo "libibex            $IBEX_LIB"
  echo "build_date_utc     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$PKG_DIR/BINDING-INFO"
ok "wrote $(basename "$PKG_DIR")/BINDING-INFO"

log "installed"
if [ "$DEST" = "$("$BINDING_PYTHON" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" ]; then
  echo
  echo "  $BINDING_PYTHON imports it already:"
  echo "    $BINDING_PYTHON -c 'import dreal; print(dreal.__version__)'"
else
  echo
  echo "  $DEST is not on $BINDING_PYTHON's default path. Use:"
  echo "    PYTHONPATH=\"$DEST\" $BINDING_PYTHON -c 'import dreal; print(dreal.__version__)'"
  echo "  or install it into that interpreter instead:"
  echo "    scripts/install_binding.sh --site-packages --python $BINDING_PYTHON"
fi
