# dReal for macOS 15+ (Apple Silicon), v0.1
#
# `make all` is the single command that takes a clean checkout to an installed,
# tested dreal. Each target is also runnable on its own.

SHELL := /bin/bash
.DEFAULT_GOAL := all

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)

.PHONY: all bootstrap ibex dreal install test check clean distclean help

all: bootstrap ibex dreal install test
	@echo
	@echo "dReal is installed and passing its acceptance tests."

bootstrap:
	scripts/bootstrap_macos.sh

ibex:
	scripts/build_ibex.sh -j $(JOBS)

dreal:
	scripts/build_dreal.sh -j $(JOBS)

install:
	scripts/install_macos.sh

# Acceptance tests only. The full "does a clean checkout reproduce this?"
# check is `make distclean && make all`.
test:
	tests/test_binary.sh

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
