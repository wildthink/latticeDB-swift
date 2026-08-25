SHELL := /bin/bash

LATTICE_SOURCE ?= $(CURDIR)/.native/latticedb
LATTICE_REPOSITORY ?= https://github.com/jeffhajewski/latticedb.git
ARTIFACT := Artifacts/Lattice.xcframework
ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.zig-cache/global

.DEFAULT_GOAL := help
.PHONY: help resolve native build test run clean

help:
	@printf '%s\n' 'LatticeDB for Swift'
	@printf '%s\n' ''
	@printf '%s\n' 'make native                                  Clone LatticeDB if needed, then build the XCFramework'
	@printf '%s\n' 'make native LATTICE_SOURCE=/path/to/latticedb  Build from an existing upstream checkout'
	@printf '%s\n' 'make resolve                                  Resolve Swift dependencies'
	@printf '%s\n' 'make build                                    Build the library and CLI'
	@printf '%s\n' 'make test                                     Run Swift tests'
	@printf '%s\n' 'make run ARGS="node create --database demo.db"  Run the CLI'
	@printf '%s\n' 'make clean                                    Remove local build outputs'

resolve:
	swift package resolve

native:
	@if test ! -f "$(LATTICE_SOURCE)/build.zig"; then \
		mkdir -p "$(dir $(LATTICE_SOURCE))"; \
		git clone --depth 1 "$(LATTICE_REPOSITORY)" "$(LATTICE_SOURCE)"; \
	fi
	@test -f "$(LATTICE_SOURCE)/build.zig" || (printf '%s\n' 'LATTICE_SOURCE must point to an upstream latticedb checkout.' >&2; exit 2)
	@mkdir -p Artifacts "$(ZIG_GLOBAL_CACHE_DIR)"
	ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" Scripts/build-apple-xcframework.sh "$(LATTICE_SOURCE)"

build: native resolve
	swift build

test: native resolve
	swift test

run: native resolve
	swift run lattice $(ARGS)

clean:
	rm -rf .build .zig-cache "$(ARTIFACT)"
