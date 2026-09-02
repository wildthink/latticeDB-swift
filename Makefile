SHELL := /bin/bash

include Native/LatticeDB.lock

LATTICE_SOURCE ?= $(CURDIR)/.native/latticedb
LATTICE_REPOSITORY ?= $(LATTICE_UPSTREAM_REPOSITORY)
ARTIFACT := Artifacts/Lattice.xcframework
LATTICE_LINUX_PREFIX ?= $(CURDIR)/Artifacts/lattice-linux
ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.zig-cache/global
UNAME_S := $(shell uname -s)
ZIG_TARGET_ARGS := $(if $(LATTICE_ZIG_TARGET),-Dtarget=$(LATTICE_ZIG_TARGET),)

.DEFAULT_GOAL := help
.PHONY: help resolve native verify-native sync-native-header check-upstream update-native native-apple native-linux linux-build linux-test build test run docs docs-memory docs-preview clean

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
	@printf '%s\n' 'make verify-native                           Verify the pinned source revision and vendored header'
	@printf '%s\n' 'make sync-native-header                      Sync both C headers from the pinned upstream source'
	@printf '%s\n' 'make check-upstream                          Check upstream releases without changing the lock'
	@printf '%s\n' 'make update-native VERSION=0.12.0            Update the pinned source, headers, and Swift version; review and test before committing'
	@printf '%s\n' 'make native-apple                            Build the macOS static XCFramework'
	@printf '%s\n' 'make native-linux                            Install a Linux shared library under Artifacts/lattice-linux'
	@printf '%s\n' 'make resolve                                  Resolve Swift dependencies'
	@printf '%s\n' 'make build                                    Build the library and CLI'
	@printf '%s\n' 'make test                                     Run Swift tests'
	@printf '%s\n' 'make run ARGS="node create --database demo.db"  Run the CLI'
	@printf '%s\n' 'make docs                                     Build the DocC archive into .build/documentation'
	@printf '%s\n' 'make docs-preview                             Serve the documentation locally'
	@printf '%s\n' 'make linux-test                               Run Swift tests against the Linux system-library install'
	@printf '%s\n' 'make clean                                    Remove local build outputs'

resolve:
	swift package resolve

$(LATTICE_SOURCE)/build.zig:
	@if test ! -f "$(LATTICE_SOURCE)/build.zig"; then \
		mkdir -p "$(dir $(LATTICE_SOURCE))"; \
		git clone --branch "$(LATTICE_UPSTREAM_REF)" --depth 1 "$(LATTICE_REPOSITORY)" "$(LATTICE_SOURCE)"; \
	fi
	@test -f "$(LATTICE_SOURCE)/build.zig" || (printf '%s\n' 'LATTICE_SOURCE must point to an upstream latticedb checkout.' >&2; exit 2)

verify-native: $(LATTICE_SOURCE)/build.zig
	bash Scripts/verify-lattice-source.sh "$(LATTICE_SOURCE)" "$(LATTICE_UPSTREAM_VERSION)" "$(LATTICE_UPSTREAM_REVISION)" Sources/CLattice/include/lattice.h Sources/CLatticeApple/include/lattice.h

sync-native-header: $(LATTICE_SOURCE)/build.zig
	bash Scripts/sync-lattice-header.sh "$(LATTICE_SOURCE)" "$(CURDIR)"

check-upstream:
	bash Scripts/check-upstream-release.sh "$(LATTICE_REPOSITORY)" "$(LATTICE_UPSTREAM_VERSION)"

update-native:
	@test -n "$(VERSION)" || (printf '%s\n' 'Specify the target release, for example: make update-native VERSION=0.12.0' >&2; exit 2)
	bash Scripts/update-lattice-source.sh "$(LATTICE_REPOSITORY)" "$(VERSION)" "$(LATTICE_SOURCE)" "$(CURDIR)"

native: $(NATIVE_TARGET)

native-apple: verify-native
	@mkdir -p Artifacts "$(ZIG_GLOBAL_CACHE_DIR)"
	ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" Scripts/build-apple-xcframework.sh "$(LATTICE_SOURCE)"

native-linux: verify-native
	@mkdir -p "$(LATTICE_LINUX_PREFIX)" "$(ZIG_GLOBAL_CACHE_DIR)"
	cd "$(LATTICE_SOURCE)" && ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" zig build -Doptimize=ReleaseSafe $(ZIG_TARGET_ARGS) --prefix "$(LATTICE_LINUX_PREFIX)"
	bash Scripts/write-native-provenance.sh "$(LATTICE_SOURCE)" "$(LATTICE_LINUX_PREFIX)" Sources/CLattice/include/lattice.h "linux-shared-library" "$(if $(LATTICE_ZIG_TARGET),$(LATTICE_ZIG_TARGET),native)"

build: native resolve
	$(SWIFT_NATIVE_ENV) swift build

test: native resolve
	$(SWIFT_NATIVE_ENV) swift test

run: native resolve
	$(SWIFT_NATIVE_ENV) swift run lattice $(ARGS)

DOCS_OUTPUT ?= $(CURDIR)/.build/documentation
# LATTICE_DOCS opts the swift-docc-plugin dependency into Package.swift. It is
# set only here so that ordinary builds, and consumers of this package, never
# resolve the plugin. See the note at the bottom of Package.swift.
DOCS_ENV := LATTICE_DOCS=1

# Building docs resolves the extra plugin dependency, which rewrites
# Package.resolved. Restore it afterwards (and on interrupt) so the committed
# lock keeps describing the dependency set that consumers actually get.
DOCS_RESOLVED_BACKUP := $(CURDIR)/.build/Package.resolved.docs-backup
define with_docs_resolved
	@mkdir -p "$(CURDIR)/.build"
	@set -eu -o pipefail; \
	cp Package.resolved "$(DOCS_RESOLVED_BACKUP)"; \
	trap 'mv -f "$(DOCS_RESOLVED_BACKUP)" Package.resolved' EXIT; \
	$(DOCS_ENV) $(SWIFT_NATIVE_ENV) $(1)
endef

docs: native
	$(call with_docs_resolved,swift package \
		--allow-writing-to-directory "$(DOCS_OUTPUT)" \
		generate-documentation --target LatticeDB \
		--warnings-as-errors \
		--output-path "$(DOCS_OUTPUT)")

# LatticeMemory documents separately: the DocC plugin builds one archive per
# target, and a cross-target symbol link would not resolve in either of them.
DOCS_MEMORY_OUTPUT ?= $(CURDIR)/.build/documentation-memory

docs-memory: native
	$(call with_docs_resolved,swift package \
		--allow-writing-to-directory "$(DOCS_MEMORY_OUTPUT)" \
		generate-documentation --target LatticeMemory \
		--warnings-as-errors \
		--output-path "$(DOCS_MEMORY_OUTPUT)")

docs-preview: native
	$(call with_docs_resolved,swift package --disable-sandbox \
		preview-documentation --target LatticeDB)

linux-build: native-linux resolve
	PKG_CONFIG_PATH="$(LATTICE_LINUX_PREFIX)/lib/pkgconfig$${PKG_CONFIG_PATH:+:$${PKG_CONFIG_PATH}}" swift build

linux-test: native-linux resolve
	PKG_CONFIG_PATH="$(LATTICE_LINUX_PREFIX)/lib/pkgconfig$${PKG_CONFIG_PATH:+:$${PKG_CONFIG_PATH}}" swift test

clean:
	rm -rf .build .zig-cache "$(ARTIFACT)" "$(LATTICE_LINUX_PREFIX)"
