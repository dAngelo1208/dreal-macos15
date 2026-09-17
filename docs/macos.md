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
| pybind11 | v2.11.1 | patch `dreal/0010`, archive SHA256 |
| Python (waf) | 3.10 | resolved by probing, see below |
| Python (Bazel, binding) | 3.11, has `distutils` | `BINDING_PYTHON_SERIES` in `versions.lock`, resolved by probing |

Notes on three of these:

- **IBEX 2.7.4_13 is a branch, not a tag.** Its commit SHA is pinned instead; a
  branch name would not reproduce.
- **Bazel 5.4.1 must be Bazel 5.4.1.** dReal's `WORKSPACE` is in the pre-bzlmod
  dialect, and later Bazels reject parts of it. `scripts/lib/common.sh` locates
  `bazelisk` specifically, not `bazel` — the `bazel` Homebrew formula installs a
  fixed Bazel that shadows bazelisk and ignores the pin — and then asserts that
  the resolved version really is 5.4.1 before using it.
- **The Python binding's interpreter is an input, not a detail.** The extension
  module is compiled against one interpreter's headers and loaded by that
  interpreter's ABI, so its series is recorded in `versions.lock` next to the
  other pins and is checked at both build and install time.

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

**`dreal/0010` — pybind11 is bumped from v2.6.2 to v2.11.1.** dReal's
`dreal/workspace.bzl` fetches pybind11 itself, and the pinned v2.6.2 dates from
December 2020. pybind11 binds CPython's internal structures rather than a stable
ABI, and Python 3.11 made `PyFrameObject` opaque, so 2.6.2 does not compile
against any interpreter the Python binding can be built for. v2.11.1 is the
oldest release that supports 3.11, and the patch changes only the revision and
the archive hash.

The companion change is in `tools/pybind11.BUILD.bazel`, which hand-maintains the
list of headers the `cc_library` exposes. That list has to match the pinned
revision: Bazel compiles against exactly the headers named there, so a header
that pybind11 adds and the list omits becomes an unresolvable `#include`. v2.11.1
has nine headers v2.6.2 did not — `common.h`, `gil.h`, `numpy.h`, the
`eigen/` subdirectory, `type_caster_pyobject_ptr.h` and the rest — and they are
added in alphabetical position, which is where they already were.

This is a version bump in a vendored dependency rather than a macOS fix, which is
why it is last in the series and separate: it is the only patch that a Linux or
x86 build of the same tree would also want, if it built the Python binding.

**`dreal/0011` — `(get-value …)` segfaulted on every value.** The SMT2 driver
formats each value through `fmt`, and `fmt` has no formatter for `mpz_class`, so
formatting one falls back to streaming it with `operator<<`. For an `mpz_class`
that operator is declared in `gmpxx.h` and defined in libgmpxx as

```cpp
std::ostream& operator<<(std::ostream&, mpz_srcptr);
```

Homebrew's libgmpxx is built by clang against libc++, so what it actually exports
is the `std::__1::` mangling; this driver is compiled by GCC against libstdc++,
so what it asks for is the `std::` one. The names differ, so the symbol is
absent rather than mismatched in version — and on arm64 dyld binds a missing
symbol to 0 instead of reporting it, so the call jumps to address 0. Every
`(get-value …)` died with `SIGSEGV` (exit 139), after having printed the opening
`(`. It reaches `ToString(const mpz_class&)` by both routes — directly for an
integer, and through `ToRational` for a real, which formats its numerator and
denominator the same way — so the value's type did not matter. Three of
upstream's own tests exercise it, and the crash was the only symptom.

The fix does not rebuild GMP. `mpz_class::get_str()`, which is what the
streaming `operator<<` ultimately calls, is defined inline in `gmpxx.h` in terms
of `mpz_get_str` — GMP's C API, which has no C++ ABI to disagree about. So
`ToString(const mpz_class&)` in `dreal/smt2/driver.cc` now calls `get_str()`
directly, and keeps upstream's convention of writing a negative integer in
SMT-LIB form, `(- 5)`. That removes the only reference in the tree to libgmpxx's
C++ interface. (`dreal/util/box.cc` prints intervals through IBEX's own
`operator<<`, and IBEX is built by the same GCC as this driver, so `get-model`
was never affected — which is why the defect could sit unnoticed: only the
`get-value` path formatted an `mpz_class`.)

`libgmpxx.4.dylib` stays in the binary's `otool -L`: dReal uses `mpz_class` and
`mpq_class` throughout, and their useful members are header-only. The point is
that nothing the binary *needs* from that library is a C++ symbol any more, and
`tests/lib/symbol-closure.sh` asserts exactly that rather than asserting the
dependency is gone.

The class of defect this belongs to — a C++ symbol that no loaded library
provides — is now checked directly rather than left to be rediscovered as a
crash; see *the symbol closure* below.

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

**`BAZEL_USE_CPP_ONLY_TOOLCHAIN`, so Xcode cannot choose the compiler.** Bazel's
auto-configured Darwin toolchain has two branches, and it picks between them by
asking its Xcode locator whether an Xcode is installed:

```python
# external/bazel_tools/tools/cpp/osx_cc_configure.bzl
if xcode_toolchains:
    # For Xcode toolchains, there's no reason to use anything other than
    # wrapped_clang ...
    cc_path = '"$(/usr/bin/dirname "$0")"/wrapped_clang'
```

The Xcode branch hardcodes Apple's clang and never looks at `CC` at all. The
other branch, `configure_unix_toolchain`, honours it. So the *same* tree, built
by the *same* script, is compiled by Homebrew GCC on a machine with only the
Command Line Tools and by Apple clang on a machine with Xcode — and both
machines report `ok gcc 16 (… via cc-wrapper.sh)` while it happens, because the
shim was handed to a toolchain that discarded it.

The clang build does not fail at the compiler, it fails at the link, with
unresolved `ibex::operator<<` symbols whose parameters are mangled
`std::__1::basic_ostream` — libc++ manglings, looking for overloads that the
GCC-built `libibex.dylib` does not export. Nothing about the message points at
the toolchain, which is the reason this is written down: it reads like a source
problem in dReal's `display` and `fmt` code, and it is not.

`BAZEL_USE_CPP_ONLY_TOOLCHAIN=1` is upstream's own switch for this — its comment
reads "Should we unconditionally *not* use xcode?" — and it is passed as a
`--repo_env` because `cc_autoconf` declares it in `environ`. dReal has no
Objective-C, so nothing is lost. Which compiler this build uses is now decided
in one place, on every machine, rather than by what the machine happens to have
installed.

**The symbol closure.** One C++ runtime in the process is not the same as every
symbol in the process being resolvable. A library built by the other compiler
exports its C++ interface under a different mangling, so a reference to it is not
a version mismatch that the loader reconciles — the symbol is simply absent.
macOS is happy to link such a reference and, on arm64, happy to bind it to 0 at
runtime, so the failure surfaces as a jump to address 0 with no message at all.

Linking catches the case where a symbol has *no* provider anywhere, which is what
the compiler shim is for. It cannot catch the case where a provider exists but
exports the name under the other ABI, because to the link editor the two names
are unrelated. `tests/lib/symbol-closure.sh` closes that gap: for a Mach-O file it
collects the undefined C++ manglings (`^__Z`, from `nm -u`), collects what the
file and its transitive dependencies define (`nm -gU`, resolving `@loader_path`
against the referring file and `@rpath` through its `LC_RPATH`), and prints the
difference demangled. Both acceptance suites run it — over the CLI in
`tests/test_binary.sh`, over `libdreal.so` and both extension modules in
`tests/test_binding.sh` — so a symbol that would jump to 0 fails the suite
instead of surviving to a crash in the field. `patches/dreal/0011` is a real
instance of the class: checking that each of the CLI's dependencies existed would
have passed a binary that segfaulted on `(get-value …)`.

C symbols are not examined. `/usr/lib` is served from the dyld shared cache and
cannot be read with `nm` offline, and a C symbol has no ABI namespace to disagree
about.

**Python 3.10 for the IBEX build.** IBEX ships Waf 2.0.12, which needs a Python
older than 3.11: it imports `imp`, removed in 3.12, and opens `wscript` files in
`rU` mode, removed in 3.11. Homebrew's `python3` is 3.14. `setup_ibex_python` in
`scripts/lib/common.sh` does not assume a version — it probes candidate
interpreters by actually importing `imp` and actually opening a file in `rU`
mode, and uses the first that works, with `/usr/bin/python3` (3.9) as a fallback
if `python@3.10` is not installed. The failure mode this avoids is subtle: a
`python3` that is new enough to look plausible and too new to run waf.

**Two Pythons, for three unrelated reasons.** Two interpreters are installed and
neither can be replaced by the other; between them they cover three roles.

`python@3.10` runs IBEX's Waf 2.0.12, which needs an interpreter older than 3.11.
`python@3.11` does the other two, and is the reason they are one interpreter
rather than two: it satisfies dReal's Bazel build *and* it is the interpreter the
extension module is compiled against. A Python with `distutils` satisfies the
Bazel side alone — dReal vendors TensorFlow's `python_configure` repository rule:

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

Note that this probe answers "which interpreter can this build use", which is a
different question from "which interpreter may load the extension module". The
binding's interpreter is not probed: it is pinned in `versions.lock` and passed
as `PYTHON_BIN_PATH` all the same, because `python_configure` needs *an* answer
either way and the include path it computes should come from the interpreter the
module is being compiled for. Where the two questions would answer differently,
the pin wins — which is why the build reports a probed `bazel python` and a
pinned `binding python` that are the same 3.11.

**The Python binding.** The extension is upstream's code — `dreal/python/` and
dReal's own `dreal_pybind_library` rule in `tools/dreal.bzl` — and nothing in it
is patched. What this project adds is a build that points it at the right
interpreter and an install that survives being copied out of the build tree.

The one upstream change it needs is the pybind11 bump in `dreal/0010`, without
which the extension does not compile against any supported interpreter.

Three properties are worth stating, because each is the reason for something in
`scripts/build_binding.sh` or `scripts/install_binding.sh`:

- **One symbolic layer per process.** `dreal_pybind_library` builds the extension
  as a `cc_binary` with `linkshared=1` over `//:dreal_shared_library`. The
  extension therefore contains no copy of the symbolic layer; it loads
  `libdreal.so`, and the two extension modules in one process share it. This is
  not cosmetic: the symbolic layer carries the variable-id counter, and a second
  copy in the same process would hand out ids that collide with the first.
  Upstream's own `dreal/test/python/odr_test.py` exists to assert exactly this,
  and `tests/test_binding.sh` runs the same assertion through the installed
  package.
- **One IBEX per machine.** The CLI and the binding must resolve the same
  `libibex.dylib`, so `install_binding.sh` does *not* copy IBEX into the package.
  All three installed Mach-O files are retargeted at `$INSTALL_ROOT/lib/libibex.dylib`
  — the one `install_macos.sh` installed — rather than at a second copy beside
  the package.
- **Nothing in the package points into the build tree.** On macOS a shared
  library records its dependencies as absolute paths, and Bazel builds inside a
  sandbox, so as built, each file records paths into the Bazel output tree. The
  installer rewrites each file's own id to where it really is, points the
  references *between* the package's files at `@loader_path`, retargets libibex
  at the install, and re-signs — then greps `otool -L` for the build root, the
  Bazel output base and any temp directory, failing if one is left. `libpython`
  is deliberately not among the package's dependencies: as an extension module
  the package resolves CPython's symbols from whichever 3.11 interpreter loads
  it, which is what lets the same build serve a Homebrew interpreter and a conda
  one.

**`-DDREAL_CHECK_INTERRUPT`, but only for the binding.** Upstream's `setup.py`
compiles the extension with this define; the Bazel build does not, so
`build_binding.sh` adds it as a `--cxxopt`. It turns the solver's inner loops
into SIGINT checks that raise, so Ctrl-C during a long `CheckSatisfiability`
returns to the Python prompt instead of leaving the interpreter stuck in C++.
The define is deliberately not applied to the CLI: it changes the solver's
behaviour on interrupt, and the CLI's own signal handling is upstream's.

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

## Known limitations

These are properties of dReal 4.21.06.2 on the dependency set pinned in
`versions.lock`. None of them is introduced by the patch series, and none is
fixed here — they are recorded so that nobody re-discovers them from scratch.

**`Minimize` returns nothing for some objectives.** Upstream's own Python tests
(`dreal/test/python/api_test.py`) include an optimisation case that comes back
empty on this stack:

```python
dreal.Minimize(2 * x * x + 6 * x + 5, dreal.And(-10 <= x, x <= 10), 0.00001)
# -> None, where the minimum is 0.5 at x = -1.5
```

It is not a general failure of the API. `Minimize(x * x, ...)` returns 0 and
`Minimize(x + y, ...)` returns 0, both through the Python binding and through the
CLI, and `tests/test_binding.sh` checks one of them. What is specific to the
failing case is the `∀` branch of the ICP: `Minimize` is implemented as
`∃z. (z = f(x)) ∧ ∀y. (⋁¬φ(y) ∨ z ≤ f(y))`, and the corpus cases that fail the
same way are all cases whose satisfiability is decided by the quantified or
integer contractor (`forall`, `(declare-fun ... Int)`, `Minimize`,
`:polytope`).

**Interval soundness is not affected.** Probes on the geometry this could hide
in behave correctly on this build: `x² = 2`, `(x-1)² = 0`, `(x-2)² = 10⁻⁷` and
`2x² + 6x + 5 = 0.5` are all `delta-sat` over `[-10, 10]`, while `(x-1)² + 1 = 0`
is `unsat`. A double root — the shape that would be lost first if the outward
rounding were wrong — is found.

**The upstream SMT2 corpus is not a usable oracle.** Measured against the
installed binary over the corpus *as upstream CI runs it*:

```
240 targets, 215 passed, 25 failed
```

The list of targets is not a glob. `dreal/test/smt2/BUILD.bazel` declares one
`smt2_test` per target with an optional `smt2`, `options` and `tags`; targets
tagged `manual` are not run by CI, six targets pass solver options
(`--smtlib2-compliant`, `-j`), several targets reuse another target's `.smt2`,
and `dreal/test/smt2/not_working/` (10 files) is not declared at all. Running
`*.smt2` with no options — the obvious reading, and what an earlier revision of
this document did — gets a different list and reports different numbers. The
comparison itself is `test.py`'s: list equality on the stripped, split lines.

The 25 failures break down as

- 5 are upstream's own argument-splitting bug, not a solver result: the
  `smt2_test` targets that pass `-j` declare `options = ["-j 4"]`, and Bazel
  passes an `args` element as one argv, so dReal is handed the single argument
  `"-j 4"`. Its flag parser rejects that and prints usage, exiting 1. Split into
  two arguments — `dreal FILE -j 4`, which is what a user types — all five match
  their `.expected` exactly. (Upstream CI cannot be passing these.)
- 3 differ only in whitespace (`define_fun_01`, `define_fun_02`,
  `github_issue_247`),
- 2 agree on the verdict and differ in the value printed (`get_value_01`,
  `get_value_02`),
- 15 are real verdict flips, all in the quantified/integer/optimisation paths
  above. Fourteen of them are conservative — `.expected` says `delta-sat` and
  this build says `unsat`, and for a bug hunt an `unsat` that is wrong is at
  least the safe direction to be wrong in. One goes the other way: `.expected`
  says `unsat` and this build says `delta-sat`. Two of the fifteen are provably
  wrong, one in each direction, and it is those two that matter:

  **`int_01` is reported `unsat` when it has a solution.** The formula is
  `a^b·c + 10a + b = 1` over `a, b, c ∈ [-10, 10]` with `c = 5`, `a, b < 10`.
  Take `a = 0, b = 1, c = 5`: `0^1·5 + 10·0 + 1 = 1`. dReal answers `unsat`.

  **`ea_02` is reported `delta-sat` when it is unsatisfiable.** It asks for an
  `x ∈ [0,8]` such that every `y ∈ [0,8]` lies in one of two radius-3 disks
  centred at `(2,2)` and `(5,5)`. `y = 0` rules out the second disk entirely,
  leaving `(x−2)² ≤ 5`, so `x ≤ 4.236`; `y = 8` rules out the first, leaving
  `x = 5`. No `x` satisfies both, and the gap is 0.76 — roughly 760δ at the
  0.001 this run uses, so it is not a precision artefact.

  Both are known upstream, and both are open issues in dReal's tracker: `#280`
  ("Same assertions are incorrectly SAT with ints and UNSAT with reals"), `#302`
  ("Geeting wrong delta-sat model on unsat query" — upstream's spelling) and
  `#321` ("Unsoundness with powers", which is the `^` in `int_01`). So they are
  properties of the solver this project builds, not of the port. That is worth
  stating plainly rather than burying: **this build's `unsat` and `delta-sat`
  answers are not reliable for quantified, integer or optimisation problems**,
  and nothing in this document should be read as claiming otherwise.

Upstream's own macOS workflow is not a second opinion on any of this. Its recent
runs are `cancelled`, not failing — it is a scheduled workflow that does not
finish — and even a green run could not cover the five `-j` targets, whose
argument construction dReal's own parser rejects.

None of this is evidence of a *regression*, because the `.expected` files do not
describe this tree. The clearest case is cosmetic and provable:
`define_fun_01.smt2.expected` expects `z : [5, 5]` for a variable declared
`Real`, but `dreal/util/box.cc` prints a continuous interval with
`os << interval`, and IBEX's `operator<<` writes `"[" << lb << "," << ub << "]"`
— `[5,5]`, no space. That is what both the pinned IBEX and this build produce. It
has been that way since before the test was committed, and the `.expected` file
has not been touched since 2020-07-11. The files in the `unsat` group are worse:
they date from 2017 and 2018 and have never been re-verified, while the solver
changed substantially up to the 4.21.06.2 release.

Note also that upstream pins IBEX by *branch*, not by revision:
`setup/mac/install_prereqs.sh` taps `dreal-deps/ibex`, whose formula builds
`ibex-2.7.4_13` at whatever the branch tip is. Their CI therefore tests against
a moving dependency, and their `.expected` files cannot be pinned to one either.
(This project pins the tip by commit — `26eeeaae`, dated 2021-08-26 — which is
the only reproducible choice for a branch.)

To re-check after bumping any pinned dependency, re-run the corpus the same way
and compare the two lists; a change in either direction is worth reading, but a
mismatch on its own means only that a `.expected` file is out of date. The 15
verdict flips are the part to watch: they are the only ones that would move if a
dependency bump changed what the solver proves.

## The environment contract

The scripts never read an ambient variable that they did not set themselves.
`scripts/lib/common.sh` is the only place that decides what the toolchain is, and
it exports everything downstream:

| Variable | Set by | Read by |
|---|---|---|
| `CC` | `setup_gcc` | IBEX's waf, Bazel's `--repo_env`. The shim, not `gcc` |
| `BAZEL_USE_CPP_ONLY_TOOLCHAIN` | `scripts/build_dreal.sh` | `cc_autoconf`, which would otherwise let Xcode pick clang |
| `CXX` | `setup_gcc` | IBEX's waf, Bazel's `--repo_env`. The real `g++` |
| `DREAL_REAL_CC` | `setup_gcc` | the shim; reaches Bazel as `--repo_env` and `--action_env` |
| `BISON` | `setup_bison_flex` | the `local_lexyacc_repository` rule |
| `PATH` | `setup_bison_flex` | waf's `bison`/`flex` lookup |
| `PKG_CONFIG` | `setup_pkg_config` | IBEX's CLP plugin, `pkg_config.bzl` |
| `PKG_CONFIG_PATH` | `setup_pkg_config_path` | `pkg_config.bzl`, `dreal/0001` |
| `IBEX_PYTHON` | `setup_ibex_python` | `scripts/build_ibex.sh` |
| `BAZEL_PYTHON` | `setup_bazel_python` | `scripts/build_dreal.sh`, which passes it as `PYTHON_BIN_PATH` |
| `BINDING_PYTHON` | `setup_binding_python` | `scripts/build_binding.sh` and `scripts/install_binding.sh`, which pass it as `PYTHON_BIN_PATH` and use it to query the ABI |
| `PYTHON_BIN_PATH` | both build scripts, as `--repo_env` | `python_configure` |
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

That whole set of flags is built in one place, `setup_bazel_flags` in
`scripts/lib/common.sh`, and both Bazel invocations use it: `build_dreal.sh` for
the CLI and `build_binding.sh` for the extension. A second copy of the list is
how the two would end up disagreeing about which GCC or which IBEX was used, and
the extension and the binary have to agree about both — they are linked into the
same process. Only `PYTHON_BIN_PATH` differs between them, and it is passed
per-build rather than in the shared list.

Both scripts run `bazel shutdown` before each build so that a long-lived server
cannot serve a stale `PKG_CONFIG_PATH` from an earlier run — a warm cache must
not be able to change what gets built.

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
