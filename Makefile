SHELL := /bin/bash

LATTICE_SOURCE ?= $(CURDIR)/.native/latticedb
LATTICE_REPOSITORY ?= https://github.com/jeffhajewski/latticedb.git
ARTIFACT := Artifacts/Lattice.xcframework
LATTICE_LINUX_PREFIX ?= $(CURDIR)/Artifacts/lattice-linux
ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.zig-cache/global
UNAME_S := $(shell uname -s)
ZIG_TARGET_ARGS := $(if $(LATTICE_ZIG_TARGET),-Dtarget=$(LATTICE_ZIG_TARGET),)

.DEFAULT_GOAL := help
.PHONY: help resolve native native-apple native-linux linux-build linux-test build test run clean

ifeq ($(UNAME_S),Darwin)
NATIVE_TARGET := native-apple
SWIFT_NATIVE_ENV :=
else ifeq ($(UNAME_S),Linux)
NATIVE_TARGET := native-linux
SWIFT_NATIVE_ENV := PKG_CONFIG_PATH="$(LATTICE_LINUX_PREFIX)/lib/pkgconfig$${PKG_CONFIG_PATH:+:$${PKG_CONFIG_PATH}}"
else
$(error Unsupported host platform: $(UNAME_S))
endif

help:
	@printf '%s\n' 'LatticeDB for Swift'
	@printf '%s\n' ''
	@printf '%s\n' 'make native                                  Build the host-native LatticeDB dependency'
	@printf '%s\n' 'make native LATTICE_SOURCE=/path/to/latticedb  Build from an existing upstream checkout'
	@printf '%s\n' 'make native-apple                            Build the macOS static XCFramework'
	@printf '%s\n' 'make native-linux                            Install a Linux shared library under Artifacts/lattice-linux'
	@printf '%s\n' 'make resolve                                  Resolve Swift dependencies'
	@printf '%s\n' 'make build                                    Build the library and CLI'
	@printf '%s\n' 'make test                                     Run Swift tests'
	@printf '%s\n' 'make run ARGS="node create --database demo.db"  Run the CLI'
	@printf '%s\n' 'make linux-test                               Run Swift tests against the Linux system-library install'
	@printf '%s\n' 'make clean                                    Remove local build outputs'

resolve:
	swift package resolve

$(LATTICE_SOURCE)/build.zig:
	@if test ! -f "$(LATTICE_SOURCE)/build.zig"; then \
		mkdir -p "$(dir $(LATTICE_SOURCE))"; \
		git clone --depth 1 "$(LATTICE_REPOSITORY)" "$(LATTICE_SOURCE)"; \
	fi
	@test -f "$(LATTICE_SOURCE)/build.zig" || (printf '%s\n' 'LATTICE_SOURCE must point to an upstream latticedb checkout.' >&2; exit 2)

native: $(NATIVE_TARGET)

native-apple: $(LATTICE_SOURCE)/build.zig
	@mkdir -p Artifacts "$(ZIG_GLOBAL_CACHE_DIR)"
	ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" Scripts/build-apple-xcframework.sh "$(LATTICE_SOURCE)"

native-linux: $(LATTICE_SOURCE)/build.zig
	@mkdir -p "$(LATTICE_LINUX_PREFIX)" "$(ZIG_GLOBAL_CACHE_DIR)"
	cd "$(LATTICE_SOURCE)" && ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" zig build -Doptimize=ReleaseSafe $(ZIG_TARGET_ARGS) --prefix "$(LATTICE_LINUX_PREFIX)"

build: native resolve
	$(SWIFT_NATIVE_ENV) swift build

test: native resolve
	$(SWIFT_NATIVE_ENV) swift test

run: native resolve
	$(SWIFT_NATIVE_ENV) swift run lattice $(ARGS)

linux-build: native-linux resolve
	PKG_CONFIG_PATH="$(LATTICE_LINUX_PREFIX)/lib/pkgconfig$${PKG_CONFIG_PATH:+:$${PKG_CONFIG_PATH}}" swift build

linux-test: native-linux resolve
	PKG_CONFIG_PATH="$(LATTICE_LINUX_PREFIX)/lib/pkgconfig$${PKG_CONFIG_PATH:+:$${PKG_CONFIG_PATH}}" swift test

clean:
	rm -rf .build .zig-cache "$(ARTIFACT)" "$(LATTICE_LINUX_PREFIX)"
