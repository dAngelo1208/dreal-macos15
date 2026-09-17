#!/bin/bash
#
# Compiler shim for the dReal/IBEX macOS build.
#
# Bazel's auto-configured Darwin C++ toolchain appends a hardcoded `-lc++` to
# every C++ link line. That flag lives in generated, machine-specific files
# under the Bazel output base (external/local_config_cc), which are not part of
# any checkout and are regenerated on the next `bazel shutdown` -- so it is not
# something this project may fix by editing, and not something a clean checkout
# would inherit. The old manual workflow patched exactly that generated file.
#
# This build compiles everything with Homebrew GCC, which targets libstdc++, so
# linking `-lc++` as well would leave the process with symbols split across two
# C++ runtimes. The shim exists solely to rewrite that one flag to `-lstdc++`;
# every other argument is passed through untouched. It is used as CC, so it must
# accept everything the toolchain sends it: compile actions, link actions, the
# `--version` and `-dumpversion` probes that identify the compiler, and `@file`
# response files (Bazel hands long link lines over that way, and the flag we
# rewrite can be inside one).
#
# The real compiler is located via DREAL_REAL_CC, which
# scripts/lib/common.sh:setup_gcc resolves and exports.

set -eo pipefail

real="${DREAL_REAL_CC:-}"
if [ -z "$real" ]; then
  echo "cc-wrapper.sh: DREAL_REAL_CC is not set; it is exported by scripts/lib/common.sh (setup_gcc)" >&2
  exit 1
fi
if [ ! -x "$real" ]; then
  echo "cc-wrapper.sh: DREAL_REAL_CC=$real is not executable" >&2
  exit 1
fi

tmp_params=()
cleanup() {
  local f
  for f in "${tmp_params[@]}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

args=()
for arg in "$@"; do
  case "$arg" in
    -lc++)
      args+=("-lstdc++")
      ;;
    @*)
      params="${arg#@}"
      if [ -r "$params" ]; then
        rewritten="$(mktemp "${TMPDIR:-/tmp}/dreal-cc-params.XXXXXX")"
        sed 's/^-lc++$/-lstdc++/' "$params" > "$rewritten"
        tmp_params+=("$rewritten")
        args+=("@$rewritten")
      else
        args+=("$arg")
      fi
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done

"$real" "${args[@]}"
