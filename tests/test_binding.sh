#!/usr/bin/env bash
#
# Acceptance tests for an installed dReal Python binding. Run after
# scripts/install_binding.sh.
#
# Like tests/test_binary.sh these are deliberately runnable without any
# build-time environment: no PKG_CONFIG_PATH, no CC/CXX, no BUILD_ROOT. If a test
# needs one of those, the install is not self-contained.
#
# Usage: tests/test_binding.sh [--dest DIR] [--python PATH] [--binary PATH]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../versions.lock
. "$ROOT/versions.lock"

DEST=""
PY=""
BINARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --python) PY="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------ interpreter ---
# The binding is loaded by one interpreter series and no other, so this is a
# lookup for that series rather than a search for something that works. brew is
# not required: PATH and the Homebrew prefix are both tried, in that order.
resolve_python() {
  command -v "python$BINDING_PYTHON_SERIES" 2>/dev/null && return 0
  local prefix
  prefix="$(brew --prefix "python@$BINDING_PYTHON_SERIES" 2>/dev/null || true)"
  [ -n "$prefix" ] && [ -x "$prefix/bin/python$BINDING_PYTHON_SERIES" ] \
    && { printf '%s\n' "$prefix/bin/python$BINDING_PYTHON_SERIES"; return 0; }
  [ -x "/opt/homebrew/bin/python$BINDING_PYTHON_SERIES" ] \
    && { printf '%s\n' "/opt/homebrew/bin/python$BINDING_PYTHON_SERIES"; return 0; }
  return 1
}

if [ -z "$PY" ]; then
  PY="$(resolve_python || true)"
fi
[ -n "$PY" ] && [ -x "$PY" ] || {
  echo "no python$BINDING_PYTHON_SERIES found; pass --python" >&2; exit 2; }

GOT_SERIES="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
[ "$GOT_SERIES" = "$BINDING_PYTHON_SERIES" ] || {
  echo "$PY is Python $GOT_SERIES, not $BINDING_PYTHON_SERIES" >&2; exit 2; }

if [ -z "$DEST" ]; then
  # Prefer the project's own install location: it is where `make all` puts the
  # binding, and it is deliberately not on any interpreter's default path.
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  if [ -n "$BREW_PREFIX" ]; then
    CANDIDATE="$BREW_PREFIX/$INSTALL_ROOT_BASENAME/lib/python$BINDING_PYTHON_SERIES/site-packages"
    [ -d "$CANDIDATE/dreal" ] && DEST="$CANDIDATE"
  fi
  [ -n "$DEST" ] \
    || DEST="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
fi

PKG_DIR="$DEST/dreal"
[ -d "$PKG_DIR" ] || {
  echo "no dReal package at $PKG_DIR" >&2
  echo "run scripts/install_binding.sh, or pass --dest DIR" >&2
  exit 2; }

PRECISION=0.001
pass=0; fail=0

check() { # check <name> <expected-substring> <actual>
  local name="$1" want="$2" got="$3"
  if printf '%s' "$got" | grep -qF -- "$want"; then
    printf '  PASS  %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n        expected to contain: %s\n        got: %s\n' \
      "$name" "$want" "$got"; fail=$((fail + 1))
  fi
}

section() { printf '\n== %s ==\n' "$1"; }

# Run a Python program read from stdin, with the staged package on the path and
# stderr folded into stdout so that a traceback reads as the failure it is.
probe() { PYTHONPATH="$DEST" "$PY" - 2>&1; }

link_paths() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

section "package identity"

MODULE="$PKG_DIR/_dreal_py.so"
ODR_MODULE="$PKG_DIR/_odr_test_module_py.so"
LIBDREAL="$PKG_DIR/libdreal.so"

for f in "$PKG_DIR/__init__.py" "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  if [ -f "$f" ]; then
    printf '  PASS  %s is installed\n' "$(basename "$f")"; pass=$((pass + 1))
  else
    printf '  FAIL  %s is missing from %s\n' "$(basename "$f")" "$PKG_DIR"
    fail=$((fail + 1))
  fi
done

for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  check "$(basename "$f") is arm64" "arm64" "$(file "$f")"
  check "$(basename "$f") is a Mach-O binary" "Mach-O 64-bit" "$(file "$f")"
done

# BINDING-INFO is what makes an installed tree self-describing: which
# interpreter series this module is for, and which pybind11 compiled it.
if [ -f "$PKG_DIR/BINDING-INFO" ]; then
  check "BINDING-INFO records pybind11 $PYBIND11_VERSION" \
        "pybind11_version   $PYBIND11_VERSION" "$(cat "$PKG_DIR/BINDING-INFO")"
  # The recorded EXT_SUFFIX is the interpreter's ABI identity. Comparing it with
  # what this interpreter reports is the ABI-lock check: a module built for one
  # series reports a suffix the other series does not.
  check "BINDING-INFO EXT_SUFFIX matches $PY" \
        "ext_suffix         $(PYTHONPATH="$DEST" "$PY" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or "")')" \
        "$(cat "$PKG_DIR/BINDING-INFO")"
else
  printf '  FAIL  BINDING-INFO is missing from %s\n' "$PKG_DIR"; fail=$((fail + 1))
fi

section "linkage"

# The extension is compiled by the GCC shim, like everything else here, so it
# must record libstdc++ and not libc++; a module built against libc++ would be
# a second C++ runtime in one process.
for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  check "$(basename "$f") links libstdc++" "libstdc++" "$(otool -L "$f")"
done
for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  if otool -L "$f" | grep -q 'libc++'; then
    printf '  FAIL  %s links libc++ as well as libstdc++\n' "$(basename "$f")"
    fail=$((fail + 1))
  else
    printf '  PASS  %s does not link libc++\n' "$(basename "$f")"
    pass=$((pass + 1))
  fi
done

# The extension compiles none of dReal itself: it loads the symbolic layer from
# libdreal.so, found as its own sibling, so that a process has exactly one copy
# of it. This is the property dreal/test/python/odr_test.py exists to guard.
for f in "$MODULE" "$ODR_MODULE"; do
  check "$(basename "$f") loads its sibling libdreal.so" \
        "@loader_path/libdreal.so" "$(otool -L "$f")"
done

# The binding is an extension module, not an embedded interpreter: it resolves
# CPython's symbols from the interpreter that loads it, so it must not link
# against libpython. (A module that did would pin one interpreter build, and
# would be unloadable by another 3.11.)
for f in "$MODULE" "$ODR_MODULE"; do
  if otool -L "$f" | grep -q 'libpython'; then
    printf '  FAIL  %s links libpython; it must resolve CPython symbols from the loading interpreter\n' \
      "$(basename "$f")"
    fail=$((fail + 1))
  else
    printf '  PASS  %s does not link libpython\n' "$(basename "$f")"
    pass=$((pass + 1))
  fi
done

# One IBEX per machine: the CLI and every file of the binding must resolve the
# same libibex.dylib, or a process could hold two copies of the library and two
# copies of everything it defines.
if [ -z "$BINARY" ]; then
  BINARY="$(command -v dreal || true)"
fi
IBEX_IN_BINARY=""
[ -n "$BINARY" ] && IBEX_IN_BINARY="$(link_paths "$BINARY" | awk '/libibex/{print $1; exit}')"
for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  if [ -z "$IBEX_IN_BINARY" ]; then
    printf '  SKIP  %s: no dreal binary to compare libibex with\n' "$(basename "$f")"
  else
    check "$(basename "$f") resolves the CLI's libibex" "$IBEX_IN_BINARY" \
          "$(link_paths "$f" | awk '/libibex/{print $1; exit}')"
  fi
done
[ -z "$IBEX_IN_BINARY" ] || [ -e "$IBEX_IN_BINARY" ] \
  || { printf '  FAIL  %s does not exist\n' "$IBEX_IN_BINARY"; fail=$((fail + 1)); }

# The installed package must stand on its own: no build root, no Bazel output
# base, no Bazel external cache, no temp directory.
LEAK="$(for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do link_paths "$f"; done \
        | grep -E '/bazel-|execroot|/\.cache/bazel|/var/folders/|/tmp/|dreal-macos15/src|ibex-install' || true)"
if [ -z "$LEAK" ]; then
  printf '  PASS  no build-root or Bazel-cache references in otool -L\n'; pass=$((pass + 1))
else
  printf '  FAIL  otool -L references a build or cache path:\n%s\n' "$LEAK"; fail=$((fail + 1))
fi

# Resolving is not the same as working. A C++ symbol whose provider was built
# against the other C++ runtime is not merely a version mismatch -- the symbol
# is absent, dyld binds it to 0, and the call jumps there with no diagnostic.
# This is how the CLI's `(get-value ...)` segfaulted; patches/dreal/0011 is the
# fix. The binding's files are checked for the same defect.
for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do
  if CLOSURE="$("$HERE/lib/symbol-closure.sh" "$f" 2>&1)"; then
    if [ -z "$CLOSURE" ]; then
      printf '  PASS  %s: every C++ symbol it needs has a provider\n' "$(basename "$f")"
      pass=$((pass + 1))
    else
      printf '  FAIL  %s has C++ symbols with no provider (a call to one jumps to 0):\n%s\n' \
        "$(basename "$f")" "$CLOSURE"; fail=$((fail + 1))
    fi
  else
    printf '  FAIL  could not compute the symbol closure of %s:\n%s\n' \
      "$(basename "$f")" "$CLOSURE"; fail=$((fail + 1))
  fi
done

# Every non-system dependency must resolve to a file that exists right now.
# @loader_path is the package's own directory: the modules name their sibling
# libdreal.so that way so the package works wherever it is installed. It is
# resolved here rather than skipped, because a stale @loader_path reference to a
# file that is not there is exactly the failure this check is for.
#
# The loop is fed by process substitution rather than a command substitution:
# bash 3.2, which is what /bin/bash is on macOS, cannot parse a case statement
# inside $( ).
UNRESOLVED=""
while IFS= read -r dep; do
  case "$dep" in
    @loader_path/*) target="$PKG_DIR/${dep#@loader_path/}" ;;
    *) target="$dep" ;;
  esac
  [ -e "$target" ] || UNRESOLVED="$UNRESOLVED$target"$'\n'
done < <(for f in "$MODULE" "$ODR_MODULE" "$LIBDREAL"; do link_paths "$f"; done \
         | grep -v '^/usr/lib/' | grep -v '^/System/' | sort -u)
if [ -z "$UNRESOLVED" ]; then
  printf '  PASS  all non-system dependencies resolve\n'; pass=$((pass + 1))
else
  printf '  FAIL  unresolved dependencies:\n%s\n' "$UNRESOLVED"; fail=$((fail + 1))
fi

section "imports without a build environment"

# Nothing from the build is on PATH and no PKG_CONFIG_PATH / CC / CXX /
# BUILD_ROOT is set, so this fails if the module needs the build tree to load.
CLEAN_OUT="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" PYTHONPATH="$DEST" \
             "$PY" -c 'import dreal; print(dreal.__version__)' 2>&1 || true)"
check "imports with a scrubbed environment" "4.21" "$CLEAN_OUT"

section "module surface"

check "dreal.__version__" "$(printf '%s' "$DREAL_VERSION" | sed 's/\.0/./')" \
      "$(probe <<'PY'
import dreal
print(dreal.__version__)
PY
)"

# __init__.py defines these aliases in Python on top of the extension, so they
# only exist if the package-level code ran.
check "logical_and/And and friends are aliased" "True" \
      "$(probe <<'PY'
import dreal
print(dreal.And is dreal.logical_and and dreal.Or is dreal.logical_or
      and dreal.Not is dreal.logical_not)
PY
)"

section "solver probes"

# delta-sat, the form the reference workflow uses: no box is supplied, so the
# result is a Box.
check "QF_NRA satisfiable -> Box" "Box" \
      "$(probe <<'PY'
import dreal
x, y, z = dreal.Variable("x"), dreal.Variable("y"), dreal.Variable("z")
f = dreal.And(0 <= x, x <= 10, 0 <= y, y <= 10, 0 <= z, z <= 10,
              dreal.sin(x) + dreal.cos(y) == z)
print(type(dreal.CheckSatisfiability(f, 0.001)).__name__)
PY
)"

# With a box, the same call reports by mutating it and returning a bool.
check "satisfiable with a caller's Box -> True" "True" \
      "$(probe <<'PY'
import dreal
x, y, z = dreal.Variable("x"), dreal.Variable("y"), dreal.Variable("z")
f = dreal.And(0 <= x, x <= 10, 0 <= y, y <= 10, 0 <= z, z <= 10,
              dreal.sin(x) + dreal.cos(y) == z)
b = dreal.Box([x, y, z])
print(dreal.CheckSatisfiability(f, 0.001, b) and b[x].diam() < 0.1)
PY
)"

check "contradictory box -> None" "None" \
      "$(probe <<'PY'
import dreal
x, y, z = dreal.Variable("x"), dreal.Variable("y"), dreal.Variable("z")
f = dreal.And(3 <= x, x <= 4, 4 <= y, y <= 5, 5 <= z, z <= 6,
              dreal.sin(x) + dreal.cos(y) == z)
print(dreal.CheckSatisfiability(f, 0.001))
PY
)"

# Optimization, which shares the solver but reports through a Box of midpoints.
check "Minimize finds the reference minimum" "0.00000" \
      "$(probe <<'PY'
import dreal
x = dreal.Variable("x")
result = dreal.Minimize(x * x, dreal.And(-10 <= x, x <= 10), 0.00001)
print("%.5f" % result[x].mid())
PY
)"

# Not a check, because it is reporting a limitation of the pinned dependency
# set rather than a property of this install: upstream's own Minimize tests in
# dreal/test/python/api_test.py use this expression, and it comes back empty
# here. The same case fails in upstream's SMT2 corpus (minimize_01, minimize_03)
# and through the CLI, so it is not something the binding introduces -- see
# "Known limitations" in docs/macos.md. It is printed rather than asserted so
# that the state is visible without being mistaken for a passing expectation.
MINIMIZE_UNSUPPORTED="$(probe <<'PY'
import dreal
x = dreal.Variable("x")
print("None" if dreal.Minimize(2 * x * x + 6 * x + 5,
                               dreal.And(-10 <= x, x <= 10), 0.00001) is None
      else "a value")
PY
)"
printf '  NOTE  Minimize(2x^2+6x+5) -> %s (known limitation, see docs/macos.md)\n' \
  "$MINIMIZE_UNSUPPORTED"

section "one symbolic layer (ODR)"

# _odr_test_module_py.so builds a Variable with its own compiled copy of the
# symbolic headers. If that copy carries its own instance counter -- two copies
# of the library in one process -- the two ids collide. Different ids mean the
# implementation is shared, which is what the pair of modules is for.
check "two modules produce distinct Variable ids" "odr-ok" \
      "$(probe <<'PY'
import dreal
import dreal._odr_test_module_py as odr_test_module
x1 = dreal.Variable("x")
x2 = odr_test_module.new_variable("x")
print("odr-ok" if x1.get_id() != x2.get_id() else "same id: %s" % x1.get_id())
PY
)"

section "conda environment"

# The motivating case for the Python binding: an interpreter the project does
# not manage. Installing into it is the user's choice (`install_binding.sh
# --site-packages --python ...` writes into their environment), so a missing
# installation is reported, not failed -- but a broken one is a failure, since
# that is the case this project exists to catch.
CONDA="$(command -v conda || true)"
for cand in "$CONDA" \
            /opt/homebrew/Caskroom/miniconda/base/bin/conda \
            "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda"; do
  [ -n "$cand" ] && [ -x "$cand" ] && { CONDA="$cand"; break; }
done
if [ -z "$CONDA" ] || [ ! -x "$CONDA" ]; then
  printf '  SKIP  conda not found\n'
elif ! "$CONDA" env list 2>/dev/null | grep -qE '(^|\s)mikl(\s|$)'; then
  printf '  SKIP  conda environment "mikl" not present\n'
else
  CONDA_OUT="$("$CONDA" run -n mikl python -c 'import dreal; print(dreal.__version__)' 2>&1 || true)"
  case "$CONDA_OUT" in
    *ModuleNotFoundError*|*"No module named"*)
      # `conda run` may prepend diagnostics of its own; take the last line.
      MIKL_PY="$("$CONDA" run -n mikl python -c 'import sys; print(sys.executable)' 2>/dev/null | tail -1 || true)"
      printf '  SKIP  dreal is not installed in the mikl environment\n'
      [ -n "$MIKL_PY" ] && printf '        scripts/install_binding.sh --site-packages --python %s\n' "$MIKL_PY"
      ;;
    *)
      check "conda run -n mikl python -c 'import dreal'" \
            "$(printf '%s' "$DREAL_VERSION" | sed 's/\.0/./')" "$CONDA_OUT"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
