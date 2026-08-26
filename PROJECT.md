# LatticeDB Swift Project

## Purpose

This package provides two products over the same LatticeDB native engine:

- `LatticeDB`: an embeddable Swift property-graph library.
- `lattice`: a CLI with an ArgumentParser command tree and a CommandREPL shell.

The project intentionally keeps the Swift API separate from how the native
library is acquired on each platform.

## Target Architecture

```text
LatticeDB (Swift API) ──> LatticeBridge (C adapter) ──> Lattice C ABI
                                     ├── CLatticeApple (static XCFramework)
                                     └── CLatticeLinux (pkg-config system library)
lattice CLI ──> LatticeDB + ArgumentParser + CommandREPL
```

`LatticeBridge` narrows the raw C API into Swift-friendly operations and owns
the C-to-JSON serialization used by query and traversal helpers. Public Swift
code should not depend directly on either `CLatticeApple` or `CLatticeLinux`.

## Native Distribution

On macOS, `Scripts/build-apple-xcframework.sh` builds arm64 and x86_64 static
libraries with Zig, lipo-merges them, and creates
`Artifacts/Lattice.xcframework`. The `CLatticeApple` target links that artifact.

On Linux, the Makefile installs LatticeDB into `Artifacts/lattice-linux` and
sets `PKG_CONFIG_PATH` so the `CLatticeLinux` system-library target discovers
the generated `lattice.pc` file. This path links the upstream shared library.

`Native/LatticeDB.lock` pins the upstream repository, release tag, semantic
version, and immutable commit. `make verify-native` compares the checkout and
both vendored headers with that lock. Generated artifacts receive a local,
ignored `Provenance.json` containing the source revision, header SHA-256, Zig
version, targets, and build time.

`Makefile` selects the appropriate native path for the host. `make native`,
`make build`, `make test`, and `make run` are the normal entry points. The
GitHub Actions workflow exercises macOS and Ubuntu builds after changes are
pushed.

Both vendored `lattice.h` copies and any generated native artifact must match
the same upstream LatticeDB release. Updating only one can compile but fail at
runtime due to C ABI drift. Use `make update-native VERSION=x.y.z` to update
the source checkout, lock, headers, and exposed Swift version together; it
intentionally leaves testing and committing to the reviewer.

## Transaction And Bridge Rules

- `Database.read` begins a read-only transaction; `Database.write` begins a
  writable transaction. The closure commits on success and rolls back on error.
- `Database.matchJSON` is deliberately read-only. The C bridge rejects native
  Cypher queries that report writes before beginning the transaction.
- C strings and JSON buffers have explicit freeing functions. Maintain the
  current paired allocation/free ownership when adding bridge APIs.
- Query parameters are typed `Value` instances carried through
  `lattice_bridge_parameter`; their string buffers are valid only for the bind
  call, matching LatticeDB's borrowed-value C API contract.
- Query results intentionally return JSON strings for now. A typed result API
  should be additive rather than changing `matchJSON`.

## Public Feature Boundaries

The core graph API covers node/edge creation, labels, scalar properties,
traversal, indexes, and native Cypher reads with bound scalar parameters.

`GraphSchema` is advisory application validation. It validates complete
property dictionaries passed to its creation helpers; it is not persisted and
does not turn LatticeDB into a schema-enforced database.

`TemporalValidity` and `TemporalAsOf` implement an opt-in valid-time property
convention. They qualify currently stored records using `validFrom`/`validTo`;
they are not native historical `as-of` snapshots. Do not add an `asOf`
transaction API until upstream exposes snapshot selection through the C ABI.

## Verification And Release Checklist

1. Run `make test`; it rebuilds native macOS artifacts and runs Swift tests.
2. Run `swift format lint Package.swift Sources Tests` and `xcrun clang-format
   --dry-run` on modified bridge C/header files.
3. Review `git diff --check` and ensure no generated `.build`, `.native`,
   `.zig-cache`, or `Artifacts` output is staged.
4. For native changes, verify the CI workflow on both macOS and Ubuntu before
   publishing a release.
5. If upstream LatticeDB changed, run `make update-native VERSION=x.y.z`, then
   rebuild the artifact from the same source revision. Run `make check-upstream`
   to discover releases; the weekly `Upstream Release Check` workflow reports
   new tags but never updates the lock automatically.
