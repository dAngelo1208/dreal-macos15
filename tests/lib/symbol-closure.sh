#!/usr/bin/env bash
#
# Report every C++ symbol a Mach-O file needs but cannot bind. Prints nothing
# when the file is clean; prints one demangled symbol per line when it is not.
# The exit status is that of the last filter, so callers test the output for
# emptiness -- which also keeps them working under `set -e`.
#
# The hazard is the libc++/libstdc++ split. This project builds dReal and IBEX
# with GNU libstdc++, while the libraries it takes from Homebrew were built with
# libc++. A C++ symbol from one of those mangles differently in each
# (`std::__1::ostream` against `std::ostream`), so it is not a version
# mismatch -- the symbol is simply absent. dyld binds it to 0, the call jumps
# there, and the process dies with no diagnostic. On arm64 there is no lazy
# binding left to warn you first.
#
# C symbols are not checked: /usr/lib lives in the shared cache and cannot be
# read with nm, and a C symbol has no ABI namespace to disagree about.
#
# Usage: symbol-closure.sh <mach-o file>

set -uo pipefail

BIN="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# <referer> <dependency as written in referer> -> the path it names. @loader_path
# is the directory of the file doing the naming, which is how the binding's
# extension modules find their sibling libdreal.so wherever the package is
# installed.
resolve_dep() {
  local referer="$1" dep="$2" rp
  case "$dep" in
    @loader_path/*)
      printf '%s/%s\n' "$(cd "$(dirname "$referer")" && pwd)" "${dep#@loader_path/}"
      ;;
    @rpath/*)
      while IFS= read -r rp; do
        [ -n "$rp" ] || continue
        if [ -e "$rp/${dep#@rpath/}" ]; then
          printf '%s/%s\n' "$rp" "${dep#@rpath/}"
          return 0
        fi
      done < <(otool -l "$referer" 2>/dev/null \
               | awk '/LC_RPATH/ {getline; getline; print $2}')
      printf '%s\n' "$dep"
      ;;
    *) printf '%s\n' "$dep" ;;
  esac
}

nm -u "$BIN" 2>/dev/null | awk '{print $NF}' | grep '^__Z' | sort -u > "$TMP/undef"

# Everything provided by the file itself, by the libraries it names, and by the
# libraries those name. The graph is shallow, so the fixed point arrives in a
# couple of passes; stopping when a pass adds no library keeps that honest if it
# ever stops being shallow.
: > "$TMP/defined"
nm -gU "$BIN" 2>/dev/null | awk '{print $NF}' >> "$TMP/defined"

otool -L "$BIN" 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -u > "$TMP/libs"
for _ in 1 2 3 4 5 6 7 8; do
  : > "$TMP/next"
  while IFS= read -r dep; do
    lib="$(resolve_dep "$BIN" "$dep")"
    # /usr/lib and /System are served from the shared cache, not from disk, and
    # anything still starting with @ could not be resolved to a file.
    case "$lib" in /usr/lib/*|/System/*|@*) continue ;; esac
    [ -f "$lib" ] || continue
    nm -gU "$lib" 2>/dev/null | awk '{print $NF}' >> "$TMP/defined"
    { while IFS= read -r sub; do
        [ -n "$sub" ] && resolve_dep "$lib" "$sub"
      done < <(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}') ; } >> "$TMP/next"
  done < "$TMP/libs"
  cat "$TMP/libs" "$TMP/next" | sort -u > "$TMP/all"
  cmp -s "$TMP/all" "$TMP/libs" && break
  mv "$TMP/all" "$TMP/libs"
done

sort -u "$TMP/defined" -o "$TMP/defined"
if command -v c++filt >/dev/null 2>&1; then
  comm -23 "$TMP/undef" "$TMP/defined" | c++filt
else
  comm -23 "$TMP/undef" "$TMP/defined"
fi
