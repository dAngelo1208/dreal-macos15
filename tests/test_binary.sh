#!/usr/bin/env bash
#
# Acceptance tests for an installed dReal. Run after scripts/install_macos.sh.
#
# These are deliberately runnable without any build-time environment: no
# PKG_CONFIG_PATH, no CC/CXX, no BUILD_ROOT. If a test needs one of those, the
# install is not self-contained.
#
# Usage: tests/test_binary.sh [--binary /path/to/dreal] [--skip-conda]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../versions.lock
. "$ROOT/versions.lock"

BINARY=""
SKIP_CONDA=0
while [ $# -gt 0 ]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --skip-conda) SKIP_CONDA=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BINARY" ]; then
  BINARY="$(command -v dreal || true)"
fi
[ -n "$BINARY" ] && [ -x "$BINARY" ] || { echo "no dreal binary found; pass --binary" >&2; exit 2; }
BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"

PRECISION=0.0001
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

# ---------------------------------------------------------------------------
section "binary identity"

check "file reports arm64" "arm64" "$(file "$BINARY")"
check "file reports Mach-O executable" "Mach-O 64-bit" "$(file "$BINARY")"
# stdout only: a version string that arrives on stderr, alongside a diagnostic,
# is not a working binary.
check "dreal --version" "v$DREAL_VERSION" "$("$BINARY" --version 2>/dev/null)"

# ---------------------------------------------------------------------------
section "linkage"

LINKAGE="$(otool -L "$BINARY")"

check "links libibex" "libibex.dylib" "$LINKAGE"
check "links libstdc++ (GCC toolchain)" "libstdc++" "$LINKAGE"

# The installed binary must stand on its own: no build root, no Bazel output
# base, no Bazel external cache, no temp directory.
LEAK="$(printf '%s\n' "$LINKAGE" | tail -n +2 \
        | grep -E '/bazel-|execroot|/\.cache/bazel|/var/folders/|/tmp/|dreal-macos15/src|ibex-install' || true)"
if [ -z "$LEAK" ]; then
  printf '  PASS  no build-root or Bazel-cache references in otool -L\n'; pass=$((pass + 1))
else
  printf '  FAIL  otool -L references a build or cache path:\n%s\n' "$LEAK"; fail=$((fail + 1))
fi

# Every non-system dependency must resolve to a file that exists right now.
UNRESOLVED=""
while IFS= read -r dep; do
  case "$dep" in
    /usr/lib/*|/System/*) continue ;;
  esac
  [ -e "$dep" ] || UNRESOLVED="$UNRESOLVED$dep"$'\n'
done < <(printf '%s\n' "$LINKAGE" | tail -n +2 | awk '{print $1}')
if [ -z "$UNRESOLVED" ]; then
  printf '  PASS  all non-system dependencies resolve\n'; pass=$((pass + 1))
else
  printf '  FAIL  unresolved dependencies:\n%s' "$UNRESOLVED"; fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
section "runs without a build environment"

# Nothing from the build is on PATH and no PKG_CONFIG_PATH / CC / CXX / BUILD_ROOT
# is set, so this fails if dReal needs the build tree to start.
CLEAN_OUT="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
             "$BINARY" --version 2>&1 || true)"
check "runs with a scrubbed environment" "v$DREAL_VERSION" "$CLEAN_OUT"

# ---------------------------------------------------------------------------
section "solver probes"

run_probe() { # run_probe <file>
  "$BINARY" --precision "$PRECISION" "$1" 2>&1 | head -1
}

check "QF_NRA satisfiable -> delta-sat" "delta-sat" \
      "$(run_probe "$HERE/smoke_qfnra.smt2")"
check "contradictory box -> unsat" "unsat" \
      "$(run_probe "$HERE/smoke_unsat.smt2")"
check "nonlinear trig -> delta-sat" "delta-sat" \
      "$(run_probe "$HERE/smoke_trig.smt2")"

# The reference workflow records this exact line; keep it pinned so a precision
# regression is visible rather than merely "some delta".
check "QF_NRA reports the requested delta" "delta-sat with delta = $PRECISION" \
      "$(run_probe "$HERE/smoke_qfnra.smt2")"

# ---------------------------------------------------------------------------
section "conda environment"

if [ "$SKIP_CONDA" -eq 1 ]; then
  printf '  SKIP  conda check disabled\n'
else
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
    # `conda run` can emit its own diagnostics; capture them separately so that
    # a version string on stderr cannot be mistaken for a successful run.
    CONDA_ERR="$("$CONDA" run -n mikl dreal --version 2>&1 >/dev/null)"
    check "conda run -n mikl dreal --version" "v$DREAL_VERSION" \
          "$("$CONDA" run -n mikl dreal --version 2>/dev/null)"
    [ -z "$CONDA_ERR" ] || printf '  WARN  conda wrote to stderr:\n        %s\n' "$CONDA_ERR"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
