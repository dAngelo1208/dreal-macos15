# Upstream licences

This project is a build wrapper: it downloads dReal and IBEX at pinned revisions,
applies the patches in `patches/`, and links them against Homebrew libraries. It
redistributes none of that source. This file records what the build depends on,
where each licence was read from, and what a redistribution of a *built* binary
would oblige.

Nothing here is legal advice, and it is an inventory rather than a per-file
audit; see [Method and limits](#method-and-limits) at the end.

## This repository

Apache License 2.0 (`LICENSE`), the same licence as dReal.

The scripts, patches and documentation here are original work, except that each
file in `patches/` is a derivative work of the upstream file it modifies, and
inherits that file's licence: `patches/dreal/` from dReal (Apache-2.0) and
`patches/ibex/` from IBEX (LGPL-3.0). No upstream source is copied into this
repository.

## The two sources built here

| Component | Revision | Licence | Where the licence was read |
|---|---|---|---|
| dReal 4.21.06.2 | `4067225c` | Apache-2.0 | `LICENSE` in the upstream tarball |
| IBEX 2.7.4_13 | `26eeeaae` | LGPL-3.0 | `LICENSE` (GNU Lesser GPL v3) and `COPYING.LESSER` in the upstream tarball |

**IBEX is the one component with real obligations.** It is LGPL-3.0, it is
modified by this project (`patches/ibex/`), and `libibex.dylib` is linked
dynamically by `dreal`. Anyone distributing a built `dreal` must therefore:

- keep the licence notice, and state that the library was modified — the
  patches in `patches/ibex/` are the complete and only record of those
  modifications;
- supply the Corresponding Source of the library as built, which is the upstream
  tarball at the commit in `versions.lock` plus the patches in `patches/ibex/`;
- keep it dynamically linked. Linking IBEX statically would make the combined
  binary subject to the LGPL's relink requirement in a way that a dynamically
  loaded library is not.

## What the installed binary links

From `otool -L` on the installed `dreal` (the list is part of the acceptance
tests; see `tests/test_binary.sh`).

| Library | Licence | Notes |
|---|---|---|
| `libibex.dylib` | LGPL-3.0 | Built here; see above |
| `libnlopt.1` | MIT | Homebrew metadata says MIT; upstream dReal annotates NLopt as "LGPL2 + MIT", because NLopt bundles some LGPL-2 components |
| `libgmpxx.4`, `libgmp.10` | LGPL-3.0-or-later OR GPL-2.0-or-later | Dual-licensed; LGPL terms apply to this use |
| `libClpSolver.1`, `libClp.1`, `libCoinUtils.3` | EPL-2.0 | |
| `libopenblas.0` | BSD-3-Clause and related BSD variants | |
| `libbz2.1.0`, `libz.1` | BSD-style / zlib | Shipped by macOS in `/usr/lib` |
| `libstdc++.6` | GPL-3.0-or-later WITH GCC-exception-3.1 | The GCC runtime; the exception is what makes an unmodified use of GCC acceptable. It lives under the Homebrew GCC prefix, not in `/usr/lib` |
| `libSystem.B` | Apple system | |

There is deliberately no `libc++` in that list: see the compiler shim in
[docs/macos.md](macos.md) for why dReal and IBEX share one C++ runtime.

## Build-time only

Nothing here is redistributed by this repository, and none of it is linked into
the result except as noted.

| Tool | Version | Licence | Notes |
|---|---|---|---|
| GCC | 16.2.0 | GPL-3.0-or-later WITH GCC-exception-3.1 | The exception covers the runtime it links into the binary |
| Bison | 3.8.2 | GPL-3.0-or-later | Applies to Bison; its generated parser carries a special exception permitting unrestricted use |
| Flex | 2.6.4 | BSD-2-Clause | The generated scanner is explicitly not covered by Flex's licence |
| pkgconf | 3.0.7 | ISC | |
| Bazel | 5.4.1 | Apache-2.0 | Downloaded by bazelisk |
| bazelisk | 1.29.0 | Apache-2.0 | |
| Python | 3.10.21 | Python-2.0 | Runs IBEX's bundled Waf 2.0.12 |

## Third-party code compiled into dReal

dReal vendors or fetches these itself. The licence column is quoted from dReal's
own annotations (`WORKSPACE`, `dreal/workspace.bzl`) and from the `LICENSE` /
`COPYING` files under its `third_party/` directory, because they are what the
build actually pulls in.

| Component | Licence | In the built binary |
|---|---|---|
| picosat | MIT | Yes, statically linked |
| cds (libcds) | BSL-1.0 | Yes, statically linked |
| spdlog | MIT | Yes, header-only |
| fmt | MIT | Yes, header-only |
| absl (`com_google_absl`) | Apache-2.0 (dReal annotates "BSD") | Partly |
| drake `libdrake_symbolic` | BSD-3-Clause | Yes, statically linked |
| tartanllama `optional` | CC0-1.0 | Yes, header-only (edited by `patches/dreal/0009`) |
| pinam45 `dynamic_bitset` | MIT | Header-only |
| progschj `threadpool` | zlib | Header-only |
| westes `flex` rules | BSD-2-Clause | No; `patches/dreal/0005` removes the dead toolchain that referenced it |
| kythe `lexyacc` rules | Apache-2.0 | No; build tooling |
| grailbio `bazel-compilation-database` | Apache-2.0 | No; build tooling |
| tensorflow (vendored subset) | Apache-2.0 | No; Bazel configure helpers only |
| googletest | BSD-3-Clause | No; tests only |
| bazel_skylib, rules_python, rules_pkg | Apache-2.0 | No; build tooling |
| google_styleguide | BSD-3-Clause | No; lint tooling |
| pycodestyle | Expat (MIT-like) | No; lint tooling |
| ezoptionparser | MIT | Only if the option-parsing variant is used |
| GMP (via dReal's `org_gmplib` rule) | LGPL-3.0-or-later OR GPL-2.0-or-later | Yes; see the runtime table |

## If you distribute a binary

- Keep `LICENSE` and `NOTICE`, and keep the upstream notices for dReal, IBEX and
  the vendored third-party components.
- Supply the source of the modified IBEX, as described above.
- Do not static-link `libibex.dylib`.
- The CLP and CoinUtils libraries are EPL-2.0. This project takes them from
  Homebrew and does not redistribute them; if you bundle them (for example
  inside a self-contained `.app`), their obligations — including making the
  source available — become yours.
- The same applies to GMP and NLopt under LGPL terms: depending on Homebrew is
  not the same as redistributing them.

## Method and limits

Licences were read from three places, in this order of preference: the `LICENSE`
/ `COPYING` files inside the pinned upstream tarballs (dReal, IBEX, and the
`third_party/` trees); Homebrew's own formula metadata
(`brew info --json=v2 --formula …`), which is what this build actually installs;
and upstream dReal's inline annotations in `WORKSPACE` and
`dreal/workspace.bzl`, which are quoted rather than verified.

No per-file audit of any vendored tree was performed, several components are
dual-licensed (GMP, NLopt) and only one branch of that choice is exercised here,
and the "in the built binary" column reflects what the Bazel build reports
compiling and linking, not a symbol-level audit. Re-verify anything in this file
before shipping binaries.
