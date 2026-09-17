# Building dReal on macOS 15+ (Apple Silicon)

This document explains why the build is shaped the way it is. If you only want
to build dReal, read the [README](../README.md). If you want to change the
build, the patch series, or the pinned versions, read this first.

## The problem

dReal 4.21.06.2 was last released in mid-2021. Its build assumes an Intel Mac
with Homebrew under `/usr/local`, Apple clang, and a toolchain that has not
changed since. On an Apple Silicon Mac running macOS 15 or later, every one of
those assumptions is wrong, and the failures are not independent: several of
them only appear after an earlier one is fixed, which is why the patch series
looks the way it does.

Two rules run through all of it:

1. **Every source change lives in `patches/`.** Nothing is fixed by editing a
   generated file in a build cache. A `.waf3-*` directory or a Bazel output base
   is derived state: it is recreated on the next run, it is not reviewable, and
   it hides the fix from anyone building from a clean checkout. When a build
   produces a wrong artefact, the fix goes into the input that produced it.
2. **The completion criterion is a clean checkout.** That the tree happens to
   compile in a warm cache is not evidence of anything. `make distclean && make
   all` is the test that matters, and it is the one to run after any change here.

## Pinned versions

`versions.lock` is the single source of truth: versions, commits and SHA256
hashes. `scripts/lib/common.sh` sources it, and `scripts/bootstrap_macos.sh`
verifies every download against its hash before extracting.

| Component | Version | Pinned by |
|---|---|---|
| dReal | 4.21.06.2 | commit `4067225c`, tarball SHA256 |
| IBEX | 2.7.4_13 | commit `26eeeaae`, tarball SHA256 |
| Bazel | 5.4.1 | `USE_BAZEL_VERSION`, checked at runtime |
| GCC | 16 (Homebrew) | resolved from `$(brew --prefix gcc)` |
| Python (waf) | 3.10 | resolved by probing, see below |
| Python (Bazel) | has `distutils` | resolved by probing, see below |

Notes on two of these:

- **IBEX 2.7.4_13 is a branch, not a tag.** Its commit SHA is pinned instead; a
  branch name would not reproduce.
- **Bazel 5.4.1 must be Bazel 5.4.1.** dReal's `WORKSPACE` is in the pre-bzlmod
  dialect, and later Bazels reject parts of it. `scripts/lib/common.sh` locates
  `bazelisk` specifically, not `bazel` — the `bazel` Homebrew formula installs a
  fixed Bazel that shadows bazelisk and ignores the pin — and then asserts that
  the resolved version really is 5.4.1 before using it.

## The patch series

`patches/series` lists the patches in application order. Each is a plain
unified diff applied with `patch -p1` at the root of the corresponding upstream
tree.

### IBEX

**`ibex/0001` — `plugins/lp_lib_clp/wscript` hardcodes `/usr/local/bin/pkg-config`.**
On Apple Silicon Homebrew installs to `/opt/homebrew`, so that path does not
exist and CLP is never found. The fix resolves `pkg-config` from the `PKG_CONFIG`
environment variable first, then from `PATH`, and fails loudly if neither
exists, rather than falling back to a path that only makes sense on Intel.

**`ibex/0002` — `ibex.pc.in` exports `-msse3` unconditionally.** The generated
`ibex.pc` is consumed by pkg-config, so this flag propagates into every consumer
of IBEX, including dReal's compile lines. `-msse3` is meaningless on arm64.
It is removed at the source, in the `.pc` template.

**`ibex/0003` — `plugins/interval_lib_direct/wscript` probes for SSE flags.**
The probe sets `-msse3`, and falls back to `-msse2` if that fails. On arm64 the
compiler accepts `-msse3` without complaint — it simply ignores it — so the probe
"succeeds" and the x86-only flag is recorded. The probe is now restricted to x86
architectures, where it was always meant to run.

These three are all the same root cause seen from three directions: IBEX assumes
x86 and assumes the Intel Homebrew layout. `scripts/build_ibex.sh` re-checks the
outcome — it fails if the installed `ibex.pc` still carries any `-msse*` flag —
and the check message explicitly says not to paper over it with `sed` on the
generated file.

### dReal

**`dreal/0001` — `pkg_config_repository` discards `PKG_CONFIG_PATH`.** This is
the single most important fix in the series.

dReal vendors Drake's `pkg_config.bzl`. Its `_run_pkg_config` builds the
environment for `pkg-config` from scratch, passing only `PKG_CONFIG_PATH` as
computed from the rule's own `pkg_config_paths` attribute. Anything the caller
exported is thrown away. This matters because `dreal/workspace.bzl` is evaluated
in the `WORKSPACE` dialect, which has no access to the environment, and so cannot
compute the active Homebrew prefix itself. The result is that exporting
`PKG_CONFIG_PATH` had no effect on the Bazel side at all: a build could appear to
succeed while resolving against a completely different IBEX than the one that was
just built, and the failure would only show up on a machine where that other IBEX
did not exist. The fix appends the caller's `PKG_CONFIG_PATH` to the rule's own
paths, and teaches the tool lookup to honour `PKG_CONFIG` before searching
`PATH`.

**`dreal/0002` — `dreal/workspace.bzl` hardcodes `/usr/local/opt/...` paths.**
These are the Intel Homebrew locations for nlopt, clp and coinutils. They are
replaced with an empty list, because the real paths now arrive through
`PKG_CONFIG_PATH` (see `dreal/0001`). An empty value is not a silent default: it
means "the caller decides", and `scripts/lib/common.sh:setup_pkg_config_path` is
the one place that decides.

**`dreal/0003` and `dreal/0004` — the GMP repository rule hardcodes
`/usr/local/opt/gmp`.** The macOS branch now resolves the Homebrew prefix at
build time, in this order: `HOMEBREW_PREFIX`, then the parent of
`command -v brew`, then `/opt/homebrew`. `GMP_PREFIX` overrides it outright. The
matching `package-macos.BUILD.bazel` uses `%{gmp_libdir}` instead of a literal
`-L/usr/local/opt/gmp/lib`, so the path is substituted rather than assumed.

**`dreal/0005` and `dreal/0006` — the flex/bison toolchain points at Intel
Homebrew.** The `lexyacc_remote` toolchain used `/usr/local/opt/flex/bin/flex`
and `/usr/local/opt/bison/bin/bison`, neither of which exists on Apple Silicon.
Rather than swap in a second set of hardcoded paths, the dead toolchain is
removed and the `local_lexyacc_repository` that already ships with dReal is used
instead. It resolves `flex` and `bison` from `PATH` (with `BISON` as an
override), which is what `scripts/lib/common.sh:setup_bison_flex` sets up. This
matters for more than macOS: it also fixes the case where Homebrew's `bison` is
keg-only and macOS's ancient `/usr/bin/bison` 2.3 is what `PATH` finds first —
2.3 cannot parse dReal's grammar.

**`dreal/0007` — `.bazelrc`.** Three things: the `--extra_toolchains` line now
names `@local_lexyacc//:lexyacc_local_toolchain` (matching `dreal/0006`);
`-Werror` becomes opt-in under a `werror` config instead of being unconditional,
because a 2021 tree does not compile warning-free under a 2026 compiler and
`-Werror` turns every new warning into a build failure; and a `macos_arm64`
config is added, which is what `scripts/build_dreal.sh` passes with
`--config=macos_arm64`.

That config does three things, each with a reason:

- `--define=dreal_compiler=gcc` selects the warning set for GCC. See
  `dreal/0008`.
- `-Wno-error` covers dReal's own code.
- `-w` for the target and host C++ compiler covers the vendored third-party
  headers — tartanllama's `optional`, fmt, spdlog, easyloggingpp and the rest —
  which are compiled as part of the tree and are not ours to fix.

**`dreal/0008` — `tools/dreal.bzl` always picks clang's warning flags on
macOS.** `_platform_copts` selects a warning set per compiler, and one of the
keys is "Apple", which assumes Apple means clang:

```python
"//tools:apple": CLANG_FLAGS + rule_copts,
```

That assumption is false here, because this build uses GCC deliberately (see
below), and Apple's `config_setting` matches on the OS constraint only. The
other two keys, `gcc_build` and `clang_build`, key on
`@bazel_tools//tools/cpp:compiler`, which Bazel 5.4.1 leaves at its default no
matter what `CC` is set to; neither ever matches, so the Apple branch always
wins and GCC is handed `-Winconsistent-missing-override` and
`-Wreturn-stack-address`, which it rejects outright.

The fix adds an explicit, OS-scoped setting:

```python
config_setting(
    name = "apple_gcc",
    constraint_values = ["@bazel_tools//platforms:osx"],
    values = {"define": "dreal_compiler=gcc"},
)
```

and puts it first in the `select`. It is a specialization of `//tools:apple`, so
Bazel resolves it in preference to the generic Apple case, and `macos_arm64`
sets the `define` that turns it on. Upstream's behaviour for a plain
`bazel build` is unchanged.

**`dreal/0009` — a vendored header is ill-formed C++.** In
`third_party/com_github_tartanllama_optional/`, the `optional<T&>`
specialization stores a pointer, has no `construct` member, and nevertheless
defines:

```cpp
template <class... Args> T &emplace(Args &&... args) noexcept {
  ...
  this->construct(std::forward<Args>(args)...);
  return value();
}
```

Nothing instantiates it — a reference cannot be constructed in place, so
`emplace` is unusable for this specialization by construction — and clang
defers the failed lookup to instantiation, so it went unnoticed. GCC 15 and
later diagnose template bodies eagerly and reject the header. The overload is
removed: repairing it is not possible, and deleting it changes nothing that
could previously have compiled.

## Decisions that are not patches

**GCC, not clang, for both IBEX and dReal.** IBEX is built with Homebrew GCC,
and a C++ library built by GCC links `libstdc++`. If dReal were built by Apple
clang it would link `libc++`, and the process would end up loading both C++
runtimes. Everything shared across that boundary — `std::string`, `std::vector`,
exceptions, allocation — would depend on the two agreeing, which they do not
guarantee. So both halves are built with the same GCC, and both build scripts
assert the result: `scripts/build_ibex.sh` fails unless `libibex.dylib` links
`libstdc++`, and `scripts/build_dreal.sh` fails unless the `dreal` binary does
too.

**The compiler shim (`scripts/toolchain/cc-wrapper.sh`).** Choosing GCC is not
sufficient on its own. Bazel's auto-configured Darwin C/C++ toolchain appends a
hardcoded `-lc++` to every C++ link line, whatever `CC` is, so a GCC-built dReal
would compile against libstdc++ headers and then link against libc++. Which
runtime a symbol binds to then depends on link order, and the two libraries both
define `operator new` and the C++ ABI entry points: the result is a binary whose
symbols are split across two runtimes, or worse, an allocator mismatch. It also
loads a second C++ runtime that nothing in the process needs.

That flag lives in generated, per-machine files under the Bazel output base
(`external/local_config_cc`). Editing them is exactly what rule 1 forbids —
they are not in any checkout, `bazel shutdown` discards them, and a clean
checkout would not reproduce the fix. (The workflow this project replaces did
patch that generated file, which is one reason it could not be reproduced
anywhere else.) Bazel 5.4.1 gives the auto-configured toolchain no supported
hook for the C++ standard library, and hand-writing a `cc_toolchain_config` for
Darwin would mean reimplementing the SDK include paths and linker flags that
Bazel gets right on its own.

So the toolchain is left alone and the compiler is wrapped instead. `CC` is a
shim in this repository that rewrites `-lc++` to `-lstdc++` and passes every
other argument through unchanged, including `@file` response files, which is how
Bazel hands over long link lines and where the flag also appears. `CXX` stays the
real `g++`, so IBEX's waf build is untouched by any of this. The shim needs to
know which GCC to forward to; `setup_gcc` exports `DREAL_REAL_CC`, which
`scripts/build_dreal.sh` passes as both a `--repo_env` (the repository rule that
identifies the compiler runs in the client environment) and an `--action_env`
(compile and link actions run in a sandbox with a stripped environment).

The evidence that it is needed is in the boundary itself: without the shim the
binary's `otool -L` lists `libc++`, and `nm -u` lists only libstdc++ manglings
(`_ZNSt7__cxx1112basic_string…`), which resolve at runtime against a
`libstdc++` that arrives transitively through `libibex`. With the shim, the
binary records `libstdc++` directly and no libc++ at all.

**Python 3.10 for the IBEX build.** IBEX ships Waf 2.0.12, which needs a Python
older than 3.11: it imports `imp`, removed in 3.12, and opens `wscript` files in
`rU` mode, removed in 3.11. Homebrew's `python3` is 3.14. `setup_ibex_python` in
`scripts/lib/common.sh` does not assume a version — it probes candidate
interpreters by actually importing `imp` and actually opening a file in `rU`
mode, and uses the first that works, with `/usr/bin/python3` (3.9) as a fallback
if `python@3.10` is not installed. The failure mode this avoids is subtle: a
`python3` that is new enough to look plausible and too new to run waf.

**A Python with `distutils` for the Bazel build.** Two different interpreters are
in play, for two unrelated reasons, and it is a coincidence that one Python
version satisfies both. dReal vendors TensorFlow's `python_configure` repository
rule, and that rule asks the interpreter it selected for its include directory:

```
python3 -c 'from distutils import sysconfig; print(sysconfig.get_python_inc())'
```

`distutils` was removed in Python 3.12. When the rule cannot get an answer, the
build stops during analysis — before a single file is compiled — with
`Problem getting python include path`. This is the failure that a CI run caught
while the same tree built fine on a developer machine, and the reason is worth
recording, because it is the kind of state that makes a build look reproducible
when it is not: `setuptools` ships its own `distutils` shim, so on an
interpreter where `setuptools` happens to be installed the import succeeds and
nothing appears to be wrong. The build was depending on an accident of one
machine's site-packages.

The rule leaves no room for guessing: it declares `PYTHON_BIN_PATH` in its
`environ`, so `--repo_env=PYTHON_BIN_PATH` decides it, and `setup_bazel_python`
in `scripts/lib/common.sh` probes candidate interpreters by running that exact
expression — not by checking a version number — and exports the first one where
`distutils` is real. `scripts/build_dreal.sh` passes the result through, the
same way it passes `PKG_CONFIG_PATH` and `BISON`. No patch is involved: the
upstream rule already supports being told, it simply was not being told.

**Ad-hoc codesigning after `install_name_tool`.** On Apple Silicon, modifying a
Mach-O binary's load commands invalidates its signature, and the kernel kills
the result. `scripts/install_macos.sh` rewrites the install names, then
re-signs both the dylib and the binary with `codesign --force --sign -`.

**The install prefix is stable.** `make install` targets
`$(brew --prefix)/opt/dreal-macos15`, never the build directory. The generated
`libibex.dylib` would otherwise record its own build path as its install name
and the installed `dreal` would depend on `~/Library/Caches/...`, which is
exactly the kind of dependency that makes a build look reproducible on the
machine that produced it and fail everywhere else. `install_macos.sh` greps
`otool -L` for the build root, the Bazel output base and any temporary directory,
and fails if it finds one.

## The environment contract

The scripts never read an ambient variable that they did not set themselves.
`scripts/lib/common.sh` is the only place that decides what the toolchain is, and
it exports everything downstream:

| Variable | Set by | Read by |
|---|---|---|
| `CC` | `setup_gcc` | IBEX's waf, Bazel's `--repo_env`. The shim, not `gcc` |
| `CXX` | `setup_gcc` | IBEX's waf, Bazel's `--repo_env`. The real `g++` |
| `DREAL_REAL_CC` | `setup_gcc` | the shim; reaches Bazel as `--repo_env` and `--action_env` |
| `BISON` | `setup_bison_flex` | the `local_lexyacc_repository` rule |
| `PATH` | `setup_bison_flex` | waf's `bison`/`flex` lookup |
| `PKG_CONFIG` | `setup_pkg_config` | IBEX's CLP plugin, `pkg_config.bzl` |
| `PKG_CONFIG_PATH` | `setup_pkg_config_path` | `pkg_config.bzl`, `dreal/0001` |
| `IBEX_PYTHON` | `setup_ibex_python` | `scripts/build_ibex.sh` |
| `BAZEL_PYTHON` | `setup_bazel_python` | `scripts/build_dreal.sh`, which passes it as `PYTHON_BIN_PATH` |
| `HOMEBREW_PREFIX` | `setup_homebrew` | `gmp_repository`, `dreal/0003` |
| `GMP_PREFIX` | `scripts/build_dreal.sh` | `gmp_repository`, `dreal/0003` |
| `USE_BAZEL_VERSION` | `setup_bazel` | bazelisk |
| `BUILD_ROOT` | `setup_build_root` | every script |

Bazel reads these through `--repo_env` rather than inheriting them, because
repository rules only see the environment they declare in `environ`, and because
the Bazel server holds a snapshot of the client environment from when it started.
Actions are a second, narrower boundary: they run sandboxed with a stripped
environment, so anything the compiler itself needs is passed with `--action_env`
as well. `DREAL_REAL_CC` therefore appears in `build_dreal.sh` twice, once for
each boundary.
`scripts/build_dreal.sh` runs `bazel shutdown` before each build so that a
long-lived server cannot serve a stale `PKG_CONFIG_PATH` from an earlier run —
a warm cache must not be able to change what gets built.

`BUILD_ROOT` (default `~/Library/Caches/dreal-macos15`) holds downloads,
extracted sources, the staged IBEX install and the logs. It is deliberately
outside the repository, and the repository's `.gitignore` does not reference it.

## Maintaining this

**Adding a patch.** Edit the source in `BUILD_ROOT/src/`, verify the build, then
regenerate the diff against the pristine copy and add it to `patches/series`.
`prepare_source` in `common.sh` keys re-extraction on a SHA256 of the whole patch
series, so editing any patch forces a fresh extraction on the next run. That is
intentional: without it, a re-run would silently keep a half-patched tree from
the previous revision of the series.

**Bumping a pinned version.** Update `versions.lock` (version, commit and
SHA256), expect at least some of the patch series not to apply, and recheck each
one. Verify the new hashes by downloading the tarball yourself — the earlier
workflow this project replaces had a 40-character SHA1 in a field labelled
SHA256, which meant nothing was ever verified.

**Testing.** `make test` runs the acceptance tests. `make distclean && make all`
is the reproducibility gate, and it is the one to run before believing any
change to the build.
