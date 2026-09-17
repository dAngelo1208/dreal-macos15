# dReal for macOS 15+ (Apple Silicon), v0.2
#
# `make all` is the single command that takes a clean checkout to an installed,
# tested dreal -- the CLI and the Python binding. Each target is also runnable
# on its own.

SHELL := /bin/bash
.DEFAULT_GOAL := all

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)

# The binding is ABI-locked to one interpreter series (versions.lock); the
# scripts find that series themselves. Set BINDING_PYTHON only to override which
# interpreter of that series is used, e.g.
#   make binding BINDING_PYTHON=/opt/homebrew/conda/envs/mikl/bin/python3.11
BINDING_PYTHON_ARG := $(if $(BINDING_PYTHON),--python $(BINDING_PYTHON),)

.PHONY: all bootstrap ibex dreal install binding install-binding test check \
        clean distclean help

all: bootstrap ibex dreal install binding install-binding test
	@echo
	@echo "dReal and its Python binding are installed and passing their acceptance tests."

bootstrap:
	scripts/bootstrap_macos.sh

ibex:
	scripts/build_ibex.sh -j $(JOBS)

dreal:
	scripts/build_dreal.sh -j $(JOBS)

install:
	scripts/install_macos.sh

# The Python extension module, built against the same libdreal.so and libibex
# the CLI uses. Staged into the dReal install by install-binding below.
binding:
	scripts/build_binding.sh -j $(JOBS) $(BINDING_PYTHON_ARG)

# Staged under the install prefix, which is deliberately not on any
# interpreter's path; the script ends by printing how to reach it. Add
# `--site-packages` (via scripts/install_binding.sh directly) to install into a
# specific interpreter instead, e.g. a conda environment.
install-binding:
	scripts/install_binding.sh $(BINDING_PYTHON_ARG)

# Acceptance tests only. The full "does a clean checkout reproduce this?"
# check is `make distclean && make all`.
test:
	tests/test_binary.sh
	tests/test_binding.sh

check: test

# Drop downloaded sources, extracted trees and the staged IBEX install. The
# Bazel output base is left alone because `make all` reuses it.
clean:
	rm -rf "$${BUILD_ROOT:-$$HOME/Library/Caches/dreal-macos15}"

# Additionally drop the Bazel output base and the bazelisk-downloaded Bazel, so
# that `make all` re-fetches and re-pins everything from scratch. This is the
# clean-checkout reproducibility gate.
distclean: clean
	rm -rf "$${HOME}/.cache/bazel" "$${HOME}/Library/Caches/bazelisk"

help:
	@sed -n '2,6p' $(MAKEFILE_LIST)
	@echo
	@grep -E '^[a-z-]+:' $(MAKEFILE_LIST) | sed 's/:.*//' | sed 's/^/  make /'
