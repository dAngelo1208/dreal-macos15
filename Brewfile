# Homebrew dependencies for dReal for macOS 15+ (Apple Silicon), v0.1.
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
brew "python@3.10"  # IBEX's bundled Waf 2.0.12 needs Python <= 3.10 (see below)

# Deliberately NOT listed:
#
#   bazel        -- the `bazel` formula installs a specific Bazel that shadows
#                   bazelisk. dReal 4.21.06.2 needs Bazel 5.4.1 exactly, and
#                   only bazelisk honours that pin.
#   python       -- unversioned; today that means 3.14, which cannot run Waf
#                   2.0.12. python@3.10 above is the one the IBEX build uses.
#   python@3.11,
#   python@3.12+ -- too new for Waf 2.0.12, which imports `imp` (removed in
#                   3.12) and opens wscripts in 'rU' mode (removed in 3.11).
