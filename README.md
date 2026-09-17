# dReal for macOS 15+ (Apple Silicon), v0.2

A reproducible build of the [dReal](https://github.com/dreal/dreal4) SMT solver
for macOS 15 and later on Apple Silicon, produced from an unmodified upstream
release plus a small, reviewable patch series.

`dReal 4.21.06.2` and `IBEX 2.7.4_13` are pinned to exact commits with verified
SHA256 hashes. From a clean checkout, one command checks the host, installs the
Homebrew dependencies, downloads and patches both sources, builds them, installs
`dreal` and the `dreal` Python module into the Homebrew prefix, and runs both
acceptance suites.

This is an independent project. It does not depend on, modify, or share any code
with any other solver wrapper.

## Status

| | |
|---|---|
| Platform | macOS 15+ on Apple Silicon (arm64) |
| Interface | `dreal` CLI and `import dreal` (Python 3.11) |
| Upstream | dReal 4.21.06.2, IBEX 2.7.4_13 |
| Bazel | 5.4.1, via bazelisk |
| pybind11 | v2.11.1 (compiled in; not a runtime dependency) |
| C++ toolchain | Homebrew GCC 16 (so dReal and IBEX share one `libstdc++`), with a compiler shim; see [docs/macos.md](docs/macos.md) |

Intel macOS and prebuilt releases are out of scope; see
[Future work](#future-work).

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) at `/opt/homebrew`

Everything else is installed by the bootstrap step. `Brewfile` lists the exact
formulae; run `brew bundle --file=Brewfile` yourself if you prefer to install
them by hand.

Two Homebrew Pythons are used, for two different halves of the build: `python@3.10`
runs IBEX's bundled Waf, and `python@3.11` is the interpreter the Python binding
is compiled for. Neither replaces the other; see `versions.lock`.

## Quick start

```bash
make all
```

`make all` is the whole pipeline: `bootstrap`, `ibex`, `dreal`, `install`,
`binding`, `install-binding`, `test`. Each target can also be run on its own:

```bash
make bootstrap        # host checks, Homebrew deps, download + verify upstream sources
make ibex             # build and stage IBEX into the build root
make dreal            # build the dreal binary with Bazel 5.4.1
make install          # install into $(brew --prefix)/opt/dreal-macos15
make binding          # build the Python extension module
make install-binding  # stage `import dreal` under the install prefix
make test             # both acceptance suites, against what is installed
```

Then:

```bash
dreal --version
dreal tests/smoke_qfnra.smt2
```

`make install` puts the binary at
`$(brew --prefix)/opt/dreal-macos15/bin/dreal` and links it to
`$(brew --prefix)/bin/dreal`. If you use a conda environment, call the absolute
path or make sure the Homebrew bin directory is on that environment's `PATH`:

```bash
conda run -n mikl dreal --version
```

## Python binding

`make install-binding` stages the module under the install prefix, at
`$(brew --prefix)/opt/dreal-macos15/lib/python3.11/site-packages`. That location
is deliberately *not* on any interpreter's default path — it is the project's
own, next to the CLI whose `libibex` it shares — so the script ends by printing
how to reach it:

```bash
PYTHONPATH="$(brew --prefix)/opt/dreal-macos15/lib/python3.11/site-packages" \
  python3.11 -c 'import dreal; print(dreal.__version__)'
```

To install it into an interpreter instead, point the installer at that
interpreter's own site-packages. This is the path for a conda environment:

```bash
scripts/install_binding.sh --site-packages --python "$(conda run -n mikl which python)"
conda run -n mikl python -c 'import dreal; print(dreal.__version__)'
```

Both forms can coexist: the staged copy is the project's, the site-packages copy
belongs to that environment, and both load the same `libdreal.so` and the same
`libibex.dylib` as the `dreal` binary, so a process never holds two copies of the
solver.

The extension is compiled against one interpreter's headers and loaded by that
interpreter's ABI, so it is bound to the Python series in `versions.lock` (3.11).
A second interpreter of the same series can load it; a different series cannot,
and the installer refuses rather than producing something that fails at import.
`make binding BINDING_PYTHON=/path/to/python3.11` selects a different interpreter
of that series, e.g. one inside a conda environment.

Ctrl-C interrupts the solver from Python. The binding is built with
`-DDREAL_CHECK_INTERRUPT`, which makes the solver's inner loops check for SIGINT
and raise, so an interrupted `CheckSatisfiability` returns to the prompt instead
of running to completion.

## What the build does with your machine

Nothing is written inside the checkout except build logs. Downloads, extracted
sources, the staged IBEX install and the Bazel output base all live under
`~/Library/Caches/dreal-macos15` (override with `BUILD_ROOT=...`) and
`~/Library/Caches/bazel`. `make clean` removes the former, `make distclean` also
removes the latter.

To prove the build really is reproducible from a clean checkout rather than from
leftovers:

```bash
make distclean && make all
```

## Repository layout

```
versions.lock              pinned versions, commits and SHA256 hashes
Brewfile                   Homebrew dependencies
Makefile                   the pipeline
LICENSE, NOTICE            this repository is Apache-2.0; see docs/upstream-licenses.md
patches/                   every source change, as reviewable patches
  series                   ordered list; see the header for provenance
  ibex/                    applied to IBEX
  dreal/                   applied to dReal
scripts/
  bootstrap_macos.sh       host checks, dependencies, source download
  build_ibex.sh            IBEX, direct interval library, staged install
  build_dreal.sh           dReal, Bazel 5.4.1, links the staged IBEX
  install_macos.sh         install, rewrite install names, ad-hoc codesign
  build_binding.sh         the Python extension module, against the same IBEX
  install_binding.sh       stage `import dreal`, rewrite install names
  toolchain/cc-wrapper.sh  compiler shim: Bazel's hardcoded -lc++ -> -lstdc++
  lib/common.sh            shared helpers; every script sources this
tests/
  smoke_qfnra.smt2         x^2 > 0.25 over [-1, 1]     -> delta-sat
  smoke_unsat.smt2         x^2 + y^2 > 3 over [0, 1]^2 -> unsat
  smoke_trig.smt2          sin x > 0.99 and cos x < 0.2 -> delta-sat
  test_binary.sh           CLI acceptance tests
  test_binding.sh          Python binding acceptance tests
docs/
  macos.md                 why each patch exists, and how to maintain it
  upstream-licenses.md     licence audit for dReal, IBEX and the deps
.github/workflows/         macOS arm64 CI: `make all` from a clean checkout
```

`patches/` is the only place source changes live. Nothing is fixed by editing
generated files in a build cache; see `docs/macos.md` for why that distinction
matters here.

## Acceptance tests

`make test` runs both suites against what is installed, with no build-time
environment set, so a test that needs `CC` or `BUILD_ROOT` fails.

`tests/test_binary.sh` checks the CLI:

- the binary is arm64 and its version string is `4.21.06.2`
- `otool -L` shows no reference to the build root, the Bazel output base or any
  temporary directory
- the binary runs with an empty environment (`env -i`), so it does not depend on
  the shell that built it
- every C++ symbol the binary needs has a provider somewhere in its dependency
  closure, which is the invariant `patches/dreal/0011` was written to restore:
  the CLI used to segfault on `(get-value …)` because `libgmpxx` is built against
  libc++ and exported the symbol under a mangling this binary does not ask for
- a QF_NRA `delta-sat` probe, an `unsat` probe, and a nonlinear trigonometric
  probe all return the expected answers
- `conda run -n mikl dreal --version` works, if that environment exists

`tests/test_binding.sh` checks the Python module:

- the package is `__init__.py` plus the two extension modules plus `libdreal.so`,
  all arm64, and `BINDING-INFO` records the interpreter series this build is
  bound to
- everything links `libstdc++` and nothing links `libc++` or `libpython`, so a
  process holds one C++ runtime and resolves CPython's symbols from whichever
  3.11 loaded it
- the two extension modules reach the symbolic layer through `@loader_path`,
  and the binding and the CLI resolve the *same* `libibex.dylib`
- no dependency points at the build root, the Bazel output base or a temp
  directory, and every non-system dependency resolves to a file that exists
- `libdreal.so` and both extension modules have every C++ symbol they need
  provided, the same check the CLI suite runs
- `import dreal` works under `env -i`, and the solver probes return the expected
  `Box`, `True`, `None` and minimum
- the two extension modules produce distinct `Variable` ids, which is the
  one-symbolic-layer invariant upstream's `odr_test.py` guards
- `conda run -n mikl python -c 'import dreal'` works, if that environment has
  the module installed

## Known limitations

`unsat` and `delta-sat` are **not reliable for quantified, integer or
optimisation problems** on this build. Two failures are proved and reproduced in
[`docs/macos.md`](docs/macos.md): an integer formula with the solution
`a = 0, b = 1, c = 5` is reported `unsat`, and a `forall` query that is
unsatisfiable is reported `delta-sat` — both are open upstream issues (`#280`,
`#302`, `#321`), not artefacts of this port. The quantifier-free nonlinear real
arithmetic the solver is known for is unaffected.

`dreal.Minimize` also returns `None` for some objectives; the same section
records which and why. `docs/macos.md` explains both, and why the upstream SMT2
corpus cannot be used as an oracle for either.

## Future work

- Intel macOS: the patch series is written to resolve the Homebrew prefix
  dynamically, so the hardcoded paths are already gone. What is untested there
  is the GCC/`libstdc++` pinning and the ad-hoc codesigning step.
- A prebuilt, signed release so that users do not need a full toolchain.
- Python series newer than 3.11. dReal's vendored `python_configure` reads the
  interpreter's include path through `distutils`, which 3.12 removed; supporting
  a newer series means patching that, and then moving the pin in `versions.lock`.


## Licence

This repository's own scripts, patches and documentation are provided under the
Apache License 2.0, matching dReal. dReal itself is Apache-2.0; IBEX is LGPL-3.0
and is linked dynamically, which is what that licence requires. See
[docs/upstream-licenses.md](docs/upstream-licenses.md) for the full audit.
