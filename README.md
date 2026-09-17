# dReal for macOS 15+ (Apple Silicon) · v0.2

A one-command build of the [dReal](https://github.com/dreal/dreal4) solver for
macOS 15 and later on Apple Silicon.

dReal reasons about **nonlinear real arithmetic**. You give it a formula; it
tells you whether a solution exists, and if one does, hands you a box that
contains it. This repository builds dReal from verified upstream sources — never
from a prebuilt binary — and installs both the command-line tool and the Python
module.

This is an independent project. It does not depend on, modify, or share any code
with any other solver wrapper.

## ✨ What you get

| | |
|---|---|
| 🖥️ Platform | macOS 15+ on Apple Silicon |
| ⌨️ Interfaces | the `dreal` command, and `import dreal` in Python 3.11 |
| 📌 Sources | dReal 4.21.06.2 and IBEX 2.7.4_13, pinned by commit and SHA256 |
| 🧪 Tests | 14 command-line and 38 Python acceptance tests, run against what was installed |

Intel Macs are not supported — see the Future work section at the end.

## 📋 What you need first

- macOS 15 or later on Apple Silicon
- Xcode Command Line Tools — `xcode-select --install`
- [Homebrew](https://brew.sh) at `/opt/homebrew`

Everything else is installed for you. If you would rather install the
dependencies yourself, run `brew bundle --file=Brewfile`.

## 🚀 Install

```bash
make all
```

That single command runs the whole pipeline: it checks your machine, installs
the Homebrew dependencies, downloads and patches the sources, builds them,
installs everything, and runs the tests. Then:

```bash
dreal --version
dreal tests/smoke_qfnra.smt2
```

Each step can also be run on its own, if you want to watch it happen or only
redo part of it:

```bash
make bootstrap        # host checks, Homebrew dependencies, download sources
make ibex             # build IBEX, the interval library dReal sits on
make dreal            # build the dreal binary
make install          # install into $(brew --prefix)/opt/dreal-macos15
make binding          # build the Python module
make install-binding  # install `import dreal`
make test             # run both acceptance suites
```

`make install` puts the binary in Homebrew's prefix and links it into your
`PATH`. Using a conda environment? Call the absolute path, or make sure
Homebrew's `bin` directory is on that environment's own path:

```bash
conda run -n mikl dreal --version
```

## 🐍 The Python module

```bash
PYTHONPATH="$(brew --prefix)/opt/dreal-macos15/lib/python3.11/site-packages" \
  python3.11 -c 'import dreal; print(dreal.__version__)'
```

To install it into a particular interpreter instead — a conda environment, for
example — point the installer at that interpreter:

```bash
scripts/install_binding.sh --site-packages --python "$(conda run -n mikl which python)"
conda run -n mikl python -c 'import dreal; print(dreal.__version__)'
```

Two things are worth knowing:

- The module is tied to **one Python series** (3.11), because it is a compiled
  extension. Any other 3.11 can load it; 3.12 cannot, and the installer says so
  rather than leaving you with an import that fails later.
- **Ctrl-C works.** The solver checks for interrupts while it is running, so a
  query you get tired of waiting for returns you to the prompt instead of
  running to completion.

## 📦 What it puts on your machine

Nothing is written inside the checkout except build logs. Downloads, extracted
sources and the build cache all live under `~/Library/Caches`. To prove that a
build really came from a clean state and not from old leftovers:

```bash
make distclean && make all
```

## ⚠️ Known limitations

This is the honest part, and it matters more than everything above.

**`unsat` and `delta-sat` are not reliable for quantified, integer or
optimisation problems.** (`unsat` means "no solution exists"; `delta-sat` means
"satisfiable up to a small tolerance δ".) Two of dReal's answers are wrong, and
we can prove it:

- An integer problem whose solution is `a = 0, b = 1, c = 5` is reported `unsat`.
- A `forall` query that has no solution at all is reported `delta-sat`.

Both are long-standing bugs in dReal itself
([#280](https://github.com/dreal/dreal4/issues/280),
[#302](https://github.com/dreal/dreal4/issues/302),
[#321](https://github.com/dreal/dreal4/issues/321)) — not something this build
introduced. Separately, `dreal.Minimize` returns `None` for some objectives.

**The quantifier-free nonlinear real arithmetic dReal is known for is
unaffected.** That is the part that is fast and correct here, and for most
people it is the part they want. [docs/macos.md](docs/macos.md) has the full
detail on both limitations.

## 🧪 What the tests check

`make test` runs both suites against what was actually installed, with no
build-time environment set — so a test that quietly depends on the shell that
built dReal fails instead of passing.

For the command-line tool: it is arm64, it reports version 4.21.06.2, it runs
under `env -i` (an empty environment), nothing in it points back at the build
directory, every C++ symbol it needs is genuinely provided by something it
links against, and three smoke queries return the right answers.

For the Python module: everything is arm64 and links a single C++ standard
library, the module and the command-line tool share one IBEX, nothing points
back into the build tree, `import dreal` works with an empty environment, the
solver returns the expected values, and two extension modules cannot
accidentally end up holding two copies of the solver's state.

## 🗺️ Repository layout

```
versions.lock        pinned versions, commits and SHA256 hashes
Brewfile             Homebrew dependencies
Makefile             the pipeline
patches/             every source change, as reviewable patches
scripts/             one script per build step
tests/               acceptance tests and smoke queries
docs/                why each patch exists; licence audit
.github/workflows/   CI: `make all` from a clean checkout
```

The build never edits dReal's or IBEX's sources in place. Every change is a
patch file under `patches/`, so you can read exactly what was changed and why —
including the full reasoning in [docs/macos.md](docs/macos.md).

## 🔭 Future work

- Intel Macs. Most of the work is already done; the untested part is the
  compiler pinning and the code-signing step.
- A prebuilt, signed release, so you do not need a toolchain at all.
- A Python series newer than 3.11. dReal's build reads the interpreter's paths
  through a module that Python removed in 3.12, so this needs a patch first.

## 📄 Licence

This repository's own scripts, patches and documentation are provided under the
Apache License 2.0, matching dReal. dReal itself is Apache-2.0; IBEX is LGPL-3.0
and is linked dynamically, which is what that licence requires. See
[docs/upstream-licenses.md](docs/upstream-licenses.md) for the full audit.
