# Homebrew dependencies for dReal for macOS 15+ (Apple Silicon), v0.2.
#
# Install with:  brew bundle --file=Brewfile
# (scripts/bootstrap_macos.sh does this for you.)
#
# Only the build depends on these. The installed dReal links libibex, libClp,
# libCoinUtils, libnlopt, libgmp, libopenblas and libstdc++ by absolute
# Homebrew paths, so the runtime dependencies must stay installed.

brew "bison"        # macOS ships bison 2.3, which cannot parse dReal's grammar
brew "flex"         # lexer generator for dreal/{dr,smt2}/parser.yy
brew "gcc"          # IBEX and dReal are both built with GCC so they share libstdc++
brew "gmp"          # exact arithmetic; dReal links libgmp and libgmpxx
brew "nlopt"        # nonlinear optimisation backend
brew "clp"          # LP solver backend for IBEX
brew "coinutils"    # CLP's utility library
brew "pkgconf"      # provides pkg-config, which both waf and Bazel query
brew "bazelisk"     # Bazel version launcher; pins Bazel 5.4.1 via versions.lock
brew "python@3.10"  # IBEX's bundled Waf 2.0.12 needs Python <= 3.10 (it imports
                    # `imp` and opens wscripts in 'rU' mode, both removed later)
brew "python@3.11"  # the Python binding's interpreter: see versions.lock

# Two Pythons, on purpose. They are used by different halves of the build and
# neither can be replaced by the other:
#
#   IBEX   -- built by its own Waf 2.0.12, which needs python@3.10 or older.
#   dReal  -- built by Bazel. Its vendored TensorFlow python_configure asks the
#             interpreter for its include directory through `distutils`, which
#             Python 3.12 removed; and the Python binding is compiled against
#             the interpreter's headers, so the interpreter is part of the
#             artifact's identity and is pinned in versions.lock (3.11).
#
# Deliberately NOT listed:
#
#   bazel        -- the `bazel` formula installs a specific Bazel that shadows
#                   bazelisk. dReal 4.21.06.2 needs Bazel 5.4.1 exactly, and
#                   only bazelisk honours that pin.
#   python       -- unversioned; today that means 3.14, which cannot run Waf
#                   2.0.12 and cannot build the binding. The two versioned
#                   formulae above are the ones the build actually uses.
#   python@3.12+ -- too new for both halves: Waf 2.0.12 cannot run on it, and
#                   python_configure has no distutils to read the include path
#                   from.
