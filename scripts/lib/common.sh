#!/usr/bin/env bash
# Shared helpers for the dReal macOS 15+ / Apple Silicon build scripts.
#
# Sourced, never executed. Every script derives the repository root from its
# own location, so the tree can be checked out anywhere and invoked from any
# working directory.

set -euo pipefail

DREAL_MACOS15_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DREAL_MACOS15_ROOT

# shellcheck source=../../versions.lock
. "$DREAL_MACOS15_ROOT/versions.lock"

# --------------------------------------------------------------- logging ---
if [ -t 1 ]; then
  _c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_blu=$'\033[34m'
else
  _c_reset=; _c_red=; _c_grn=; _c_ylw=; _c_blu=
fi

log()  { printf '%s==>%s %s\n' "$_c_blu" "$_c_reset" "$*"; }
ok()   { printf '%s ok %s %s\n' "$_c_grn" "$_c_reset" "$*"; }
warn() { printf '%swarn%s %s\n' "$_c_ylw" "$_c_reset" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# ------------------------------------------------------------ host checks ---
require_apple_silicon() {
  [ "$(uname -s)" = "Darwin" ] || die "this build targets macOS; found $(uname -s)"
  local arch; arch="$(uname -m)"
  [ "$arch" = "arm64" ] || die "v0.1 targets Apple Silicon (arm64); found $arch.

Intel macOS is out of scope for v0.1. If you are on an Intel Mac, Homebrew
installs under /usr/local and the IBEX/libstdc++ pinning assumptions do not
hold. See docs/macos.md."
}

require_macos_version() {
  local want_major="${1:-15}"
  local ver; ver="$(sw_vers -productVersion)"
  local major="${ver%%.*}"
  [ "$major" -ge "$want_major" ] \
    || die "macOS $want_major+ required; found $ver"
  ok "macOS $ver"
}

# ------------------------------------------------------------ toolchain ----
setup_homebrew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew not found on PATH.

Install it from https://brew.sh, then re-run scripts/bootstrap_macos.sh."
  BREW_PREFIX="$(brew --prefix)"
  export BREW_PREFIX
  export HOMEBREW_PREFIX="$BREW_PREFIX"
  ok "Homebrew prefix $BREW_PREFIX"
}

# Homebrew's bison and flex are keg-only, and macOS ships bison 2.3, which cannot
# parse dReal's parser.yy. Pin to the Homebrew ones both by name (BISON is read by
# the Bazel lexyacc repository rule) and by PATH, because IBEX's waf resolves
# bison/flex by searching PATH and would otherwise find /usr/bin/bison.
setup_bison_flex() {
  local bison_prefix flex_prefix
  bison_prefix="$(brew --prefix bison 2>/dev/null || true)"
  flex_prefix="$(brew --prefix flex 2>/dev/null || true)"
  [ -n "$bison_prefix" ] && [ -x "$bison_prefix/bin/bison" ] \
    || die "Homebrew bison not found; run scripts/bootstrap_macos.sh"
  [ -n "$flex_prefix" ] && [ -x "$flex_prefix/bin/flex" ] \
    || die "Homebrew flex not found; run scripts/bootstrap_macos.sh"
  export BISON="$bison_prefix/bin/bison"
  export PATH="$bison_prefix/bin:$flex_prefix/bin:$PATH"
  ok "bison $("$BISON" --version | head -1)"
  ok "flex  $("$flex_prefix/bin/flex" --version | head -1)"
}

# dReal 4.21.06.2 must be compiled with the same C++ runtime as the IBEX it
# links against. Both are built with Homebrew GCC, so everything links one
# libstdc++.
#
# CXX is the real Homebrew g++; CC is a shim in this repository
# (scripts/toolchain/cc-wrapper.sh) that forwards to the real gcc. Bazel's
# auto-configured Darwin toolchain hardcodes `-lc++` on every C++ link line, and
# the shim is where that gets rewritten to `-lstdc++`. See the shim's header for
# why it is not fixed anywhere else.
setup_gcc() {
  local gcc_prefix suffix wrapper
  gcc_prefix="$(brew --prefix gcc 2>/dev/null || true)"
  [ -n "$gcc_prefix" ] && [ -d "$gcc_prefix/bin" ] \
    || die "Homebrew gcc not found; run scripts/bootstrap_macos.sh"
  suffix="$(find "$gcc_prefix/bin" -maxdepth 1 -type f -name 'gcc-[0-9]*' \
              -exec basename {} \; 2>/dev/null | sed 's/^gcc-//' | sort -n | tail -1)"
  [ -n "$suffix" ] || die "no gcc-<version> found under $gcc_prefix/bin"

  wrapper="$DREAL_MACOS15_ROOT/scripts/toolchain/cc-wrapper.sh"
  [ -x "$wrapper" ] \
    || die "$wrapper is not executable; run: chmod +x \"$wrapper\""

  export GCC_PREFIX="$gcc_prefix"
  export GCC_SUFFIX="$suffix"
  export DREAL_REAL_CC="$gcc_prefix/bin/gcc-$suffix"
  export DREAL_REAL_CXX="$gcc_prefix/bin/g++-$suffix"
  export CC="$wrapper"
  export CXX="$DREAL_REAL_CXX"
  [ -x "$DREAL_REAL_CC" ] && [ -x "$CXX" ] \
    || die "compilers not executable: $DREAL_REAL_CC / $CXX"
  ok "gcc $("$DREAL_REAL_CC" -dumpversion) ($DREAL_REAL_CC, via $(basename "$CC"))"
}

setup_pkg_config() {
  local pc
  pc="$BREW_PREFIX/bin/pkg-config"
  [ -x "$pc" ] || die "pkg-config not found at $pc; run scripts/bootstrap_macos.sh"
  export PKG_CONFIG="$pc"
  ok "pkg-config $("$pc" --version)"
}

# Resolve bazelisk directly rather than the `bazel` shim. Homebrew also ships a
# plain `bazel` formula, so a `bazel` on PATH is not guaranteed to be bazelisk,
# and only bazelisk honours the version pin.
setup_bazel() {
  command -v bazelisk >/dev/null 2>&1 || die "bazelisk not found; run scripts/bootstrap_macos.sh"
  export BAZELISK="$(command -v bazelisk)"
  export USE_BAZEL_VERSION="$BAZEL_VERSION"
  local got
  got="$("$BAZELISK" version 2>/dev/null | sed -n 's/^Build label: //p' | head -1)"
  [ "$got" = "$BAZEL_VERSION" ] \
    || die "bazelisk resolved Bazel '$got', expected $BAZEL_VERSION"
  ok "bazel $got (via $BAZELISK)"
}

# IBEX ships Waf 2.0.12, which imports the `imp` module (removed in Python 3.12)
# and opens wscript files in 'rU' mode (removed in 3.11). Only Python <= 3.10 can
# run it, and Homebrew's python3 is far newer, so the interpreter that happens to
# be first on PATH will not work. Probe candidates and pin one that really does.
_ibex_python_ok() {
  "$1" - >/dev/null 2>&1 <<'PY'
import os, sys, tempfile, warnings
warnings.simplefilter("ignore")
import imp  # noqa: F401  -- removed in Python 3.12
f = tempfile.NamedTemporaryFile(delete=False)
f.close()
open(f.name, "rU").close()  # noqa: UP015 -- 'U' mode removed in Python 3.11
os.unlink(f.name)
PY
}

setup_ibex_python() {
  local prefix py
  local -a candidates=()

  prefix="$(brew --prefix python@3.10 2>/dev/null || true)"
  [ -n "$prefix" ] && candidates+=("$prefix/bin/python3.10")
  # The Command Line Tools interpreter is a usable fallback: it is Python 3.9
  # today and needs no extra formula.
  candidates+=("/usr/bin/python3")
  py="$(command -v python3 2>/dev/null || true)"
  [ -n "$py" ] && candidates+=("$py")

  for py in "${candidates[@]}"; do
    [ -x "$py" ] || continue
    if _ibex_python_ok "$py"; then
      export IBEX_PYTHON="$py"
      ok "waf python $("$py" -c 'import sys; print(sys.version.split()[0])') ($py)"
      return 0
    fi
  done

  die "no Python that can run IBEX's bundled Waf 2.0.12 was found.

Waf 2.0.12 imports 'imp' (removed in Python 3.12) and opens wscripts in 'rU'
mode (removed in 3.11), so it needs Python <= 3.10. Tried:
$(printf '  %s\n' "${candidates[@]}")

Run scripts/bootstrap_macos.sh to install Homebrew python@3.10."
}

# dReal's Bazel build fetches `local_config_python`, a vendored TensorFlow
# repository rule, which asks the interpreter Bazel picked for its include
# directory:
#
#   python3 -c 'from distutils import sysconfig; print(sysconfig.get_python_inc())'
#
# `distutils` was removed in Python 3.12, so a modern interpreter fails the
# fetch and the build aborts during analysis, before a single file is compiled.
# Why this can pass on one machine and fail on another is worth knowing: if the
# interpreter happens to have `setuptools` installed, setuptools' own distutils
# shim answers the import and nothing looks wrong. That is a property of the
# machine, not of this build, and it is what the CI run caught. So the
# interpreter is chosen here -- by running the same expression the rule runs --
# and handed to Bazel as PYTHON_BIN_PATH; the rule declares it in `environ`, so
# `--repo_env` reaches it (see scripts/build_dreal.sh).
_bazel_python_ok() {
  local inc
  inc="$("$1" -c 'from distutils import sysconfig; print(sysconfig.get_python_inc())' 2>/dev/null)" \
    || return 1
  [ -n "$inc" ] && [ -d "$inc" ]
}
setup_bazel_python() {
  local prefix py
  local -a candidates=()

  prefix="$(brew --prefix python@3.10 2>/dev/null || true)"
  [ -n "$prefix" ] && candidates+=("$prefix/bin/python3.10")
  # The Command Line Tools interpreter is a usable fallback: it is Python 3.9
  # today, which still ships distutils.
  candidates+=("/usr/bin/python3")
  py="$(command -v python3 2>/dev/null || true)"
  [ -n "$py" ] && candidates+=("$py")

  for py in "${candidates[@]}"; do
    [ -x "$py" ] || continue
    if _bazel_python_ok "$py"; then
      export BAZEL_PYTHON="$py"
      ok "bazel python $("$py" -c 'import sys; print(sys.version.split()[0])') ($py)"
      return 0
    fi
  done

  die "no Python with a working distutils was found for dReal's Bazel build.

dReal's local_config_python rule asks the interpreter for its include directory
via 'from distutils import sysconfig', and distutils was removed in Python 3.12.
Tried:
$(printf '  %s\n' "${candidates[@]}")

This can look like it works when the interpreter happens to have setuptools
installed, because setuptools provides a distutils shim; that is an accident of
the machine and not something to depend on.
Run scripts/bootstrap_macos.sh to install Homebrew python@3.10."
}

# ------------------------------------------------------------- build env ---
# BUILD_ROOT holds downloaded tarballs, extracted sources and the staged IBEX
# install. It is deliberately outside the repository: the acceptance criteria
# require the installed artefacts to be reproducible from a clean checkout,
# not that they derive from anything checked in here.
setup_build_root() {
  BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/dreal-macos15}"
  export BUILD_ROOT
  export BUILD_SRC="$BUILD_ROOT/src"
  export BUILD_WORK="$BUILD_ROOT/work"

  export IBEX_INSTALL="$BUILD_ROOT/ibex-install"
  export IBEX_SRC="$BUILD_SRC/$IBEX_SRCDIR"
  export DREAL_SRC="$BUILD_SRC/$DREAL_SRCDIR"

  mkdir -p "$BUILD_SRC" "$BUILD_WORK"
}

# The single place that decides what pkg-config can see. Everything downstream
# (waf, bazel repository rules) reads this.
#
# PKG_CONFIG_PATH is the mechanism by which the *active* Homebrew prefix reaches
# Bazel: dreal/workspace.bzl is evaluated in the WORKSPACE dialect, which cannot
# read the environment, so its pkg_config_paths are empty by patch and
# pkg_config.bzl appends this value instead.
setup_pkg_config_path() {
  export PKG_CONFIG_PATH="$IBEX_INSTALL/share/pkgconfig:$BREW_PREFIX/lib/pkgconfig"
  local dep
  for dep in nlopt clp coinutils; do
    local p; p="$(brew --prefix "$dep" 2>/dev/null || true)"
    [ -n "$p" ] && [ -d "$p/lib/pkgconfig" ] && PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$p/lib/pkgconfig"
  done
  ok "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
}

# --------------------------------------------------------------- sources ---
# Download and SHA256-verify. Re-running is cheap: a verified tarball is reused.
fetch_verified() {
  local url="$1" sha="$2" out="$3"
  if [ -f "$out" ] && printf '%s  %s\n' "$sha" "$out" | shasum -a 256 -c - >/dev/null 2>&1; then
    ok "cached  $(basename "$out")"
    return 0
  fi
  log "fetch   $url"
  curl --fail --location --retry 3 --retry-delay 2 -o "$out.part" "$url" \
    || die "download failed: $url"
  mv "$out.part" "$out"
  printf '%s  %s\n' "$sha" "$out" | shasum -a 256 -c - >/dev/null 2>&1 \
    || die "SHA256 mismatch for $(basename "$out")
  expected $sha
  actual   $(shasum -a 256 "$out" | awk '{print $1}')"
  ok "verified $(basename "$out")"
}

# Extract and patch, keyed on a hash of the patch series.
#
# The stamp is the whole point: editing any patch changes the hash, which forces
# a fresh extraction, so a re-run always reflects the current patches rather
# than a half-patched tree left over from a previous revision.
prepare_source() {
  local tarball="$1" srcdir="$2" patch_dir="$3" label="$4"
  local dest="$BUILD_SRC/$srcdir"
  local stamp="$BUILD_WORK/$label.stamp"
  local sig p

  [ -e "$patch_dir" ] || die "$label: no patch directory at $patch_dir"
  sig="$(cat "$patch_dir"/*.patch | shasum -a 256 | awk '{print $1}')"

  if [ -d "$dest" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sig" ]; then
    ok "$label: sources already extracted and patched (${sig:0:12})"
    return 0
  fi

  rm -rf "$dest"
  tar -xzf "$tarball" -C "$BUILD_SRC"
  [ -d "$dest" ] || die "$label: expected $dest after extracting $tarball"

  for p in "$patch_dir"/*.patch; do
    [ -e "$p" ] || die "$label: no patches found in $patch_dir"
    patch -p1 -d "$dest" --forward --silent < "$p" \
      || die "$label: $(basename "$p") failed to apply to $dest"
  done

  printf '%s' "$sig" > "$stamp"
  ok "$label: extracted and patched (${sig:0:12})"
}

# ------------------------------------------------------------- reporting ---
# Record enough about the machine to explain a build later. Written next to the
# installed artefacts, never into them.
write_build_info() {
  local out="$1"
  {
    echo "dreal_version      $DREAL_VERSION"
    echo "dreal_commit       $DREAL_COMMIT"
    echo "dreal_sha256       $DREAL_SHA256"
    echo "ibex_version       $IBEX_VERSION"
    echo "ibex_commit        $IBEX_COMMIT"
    echo "ibex_sha256        $IBEX_SHA256"
    echo "bazel_version      $BAZEL_VERSION"
    echo "os                 $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "arch               $(uname -m)"
    echo "homebrew_prefix    $BREW_PREFIX"
    echo "homebrew_version   $(brew --version | head -1)"
    echo "cc                 ${DREAL_REAL_CC:-${CC:-unknown}}"
    echo "cxx                ${DREAL_REAL_CXX:-${CXX:-unknown}}"
    echo "cc_version         $("${DREAL_REAL_CC:-${CC:-cc}}" -dumpversion 2>/dev/null || echo unknown)"
    echo "cc_wrapper         ${CC:-unknown}"
    echo "cc_wrapper_sha256  $(shasum -a 256 "${CC:-/dev/null}" 2>/dev/null | awk '{print $1}')"
    echo "pkg_config         ${PKG_CONFIG:-unknown}"
    echo "bazel_python       ${BAZEL_PYTHON:-unknown}"
    echo "build_root         ${BUILD_ROOT:-unknown}"
    echo "build_date_utc     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$out"
  ok "wrote $(basename "$out")"
}
