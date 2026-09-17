# dReal for macOS 15+ (Apple Silicon), v0.1

A reproducible build of the [dReal](https://github.com/dreal/dreal4) SMT solver
for macOS 15 and later on Apple Silicon, produced from an unmodified upstream
release plus a small, reviewable patch series.

`dReal 4.21.06.2` and `IBEX 2.7.4_13` are pinned to exact commits with verified
SHA256 hashes. From a clean checkout, one command checks the host, installs the
Homebrew dependencies, downloads and patches both sources, builds them, installs
`dreal` into the Homebrew prefix, and runs the acceptance tests.

This is an independent project. It does not depend on, modify, or share any code
with any other solver wrapper.

## Status

| | |
|---|---|
| Platform | macOS 15+ on Apple Silicon (arm64) |
| Interface | `dreal` CLI only; no Python binding in v0.1 |
| Upstream | dReal 4.21.06.2, IBEX 2.7.4_13 |
| Bazel | 5.4.1, via bazelisk |
| C++ toolchain | Homebrew GCC 16 (so dReal and IBEX share one `libstdc++`), with a compiler shim; see [docs/macos.md](docs/macos.md) |

Intel macOS and prebuilt releases are out of scope for v0.1; see
[Future work](#future-work).

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) at `/opt/homebrew`

Everything else is installed by the bootstrap step. `Brewfile` lists the exact
formulae; run `brew bundle --file=Brewfile` yourself if you prefer to install
them by hand.

## Quick start

```bash
make all
```

`make all` is the whole pipeline: `bootstrap`, `ibex`, `dreal`, `install`,
`test`. Each target can also be run on its own:

```bash
make bootstrap   # host checks, Homebrew deps, download + verify upstream sources
make ibex        # build and stage IBEX into the build root
make dreal       # build the dreal binary with Bazel 5.4.1
make install     # install into $(brew --prefix)/opt/dreal-macos15
make test        # acceptance tests against the installed binary
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
  toolchain/cc-wrapper.sh  compiler shim: Bazel's hardcoded -lc++ -> -lstdc++
  lib/common.sh            shared helpers; every script sources this
tests/
  smoke_qfnra.smt2         x^2 > 0.25 over [-1, 1]     -> delta-sat
  smoke_unsat.smt2         x^2 + y^2 > 3 over [0, 1]^2 -> unsat
  smoke_trig.smt2          sin x > 0.99 and cos x < 0.2 -> delta-sat
  test_binary.sh           acceptance tests
docs/
  macos.md                 why each patch exists, and how to maintain it
  upstream-licenses.md     licence audit for dReal, IBEX and the deps
.github/workflows/         macOS arm64 CI: `make all` from a clean checkout
```

`patches/` is the only place source changes live. Nothing is fixed by editing
generated files in a build cache; see `docs/macos.md` for why that distinction
matters here.

## Acceptance tests

`make test` runs `tests/test_binary.sh`, which checks:

- the binary is arm64 and its version string is `4.21.06.2`
- `otool -L` shows no reference to the build root, the Bazel output base or any
  temporary directory
- the binary runs with an empty environment (`env -i`), so it does not depend on
  the shell that built it
- a QF_NRA `delta-sat` probe, an `unsat` probe, and a nonlinear trigonometric
  probe all return the expected answers
- `conda run -n mikl dreal --version` works, if that environment exists

## Future work

- Intel macOS: the patch series is written to resolve the Homebrew prefix
  dynamically, so the hardcoded paths are already gone. What is untested there
  is the GCC/`libstdc++` pinning and the ad-hoc codesigning step.
- A prebuilt, signed release so that users do not need a full toolchain.
- A Python binding, restoring `import dreal` for downstream consumers.

## Licence

This repository's own scripts, patches and documentation are provided under the
Apache License 2.0, matching dReal. dReal itself is Apache-2.0; IBEX is LGPL-3.0
and is linked dynamically, which is what that licence requires. See
[docs/upstream-licenses.md](docs/upstream-licenses.md) for the full audit.
