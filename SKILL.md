---
name: latticedb-swift
description: Use the LatticeDB Swift package to embed a property graph, store evidence-backed memory with LatticeMemory, run parameterized native Cypher queries, or operate its CLI and REPL. Use when Swift code needs local graph storage or a local memory layer that keeps its provenance; do not use for remote graph services or historical database snapshots.
---

# LatticeDB For Swift

Use `import LatticeDB` for application code. Keep code on the public Swift API;
do not import `LatticeBridge` or the `CLattice*` targets from consumers.

## Core Use

- Open a `Database` with `Database(path:)`.
- Use `database.write` for mutations and `database.read` for graph reads. The
  closure owns the transaction lifetime and commits only when it returns
  successfully.
- Represent scalar values with `Value`. CLI-style inference is not part of the
  library API; pass the intended `Value` case explicitly.
- Run native Cypher with `matchJSON(_:parameters:)`. Always bind outside input
  with the `parameters` dictionary rather than interpolating it into Cypher.

```swift
let database = try Database(path: "app.db")
let person = try database.write { transaction in
    let person = try transaction.createNode(label: "Person")
    try transaction.setProperty("name", onNode: person, to: .string("Ada"))
    return person
}
let rows = try database.matchJSON(
    "MATCH (person:Person) WHERE person.name = $name RETURN person",
    parameters: ["name": .string("Ada")]
)
```

## Optional Modeling

- Use `GraphSchema` only when the application wants advisory validation before
  creating a complete node or edge. It does not impose storage constraints and
  does not validate arbitrary later property edits.
- Use `TemporalValidity` to store a current-data valid-time interval in
  `validFrom` and `validTo` properties. Use `TemporalAsOf` to generate a safe
  Cypher predicate and binding for that convention.
- Do not describe `TemporalAsOf` as a historical snapshot: current LatticeDB C
  APIs do not select a past MVCC snapshot.

## Memory Layer

- Use `import LatticeMemory` when the application needs records that keep their
  provenance. `MemoryStore` is a separate product built on `Database`; the graph
  stays reachable as `store.database`.
- Store raw text as `EvidenceDraft`; derived values are `Assertion`s that cite
  the evidence they came from. Declare every slot in the `MemorySchema` — an
  `Extractor` can propose anything and the schema decides what is written.
- Values supersede rather than overwrite. Use `currentAssertions(in:)` for now
  and `assertions(validAt:in:)` for what was believed then.
- Every read is scoped: a record is visible only when each dimension it declares
  appears in the querying `Scope` with the same value.
- Use `retrieve(_:)` for a ranked, budgeted, scoped result. Read
  `result.trace` for what was dropped and why, and an item's `explanation` for
  which lanes placed it. Do not treat `item.score` as comparable across results.
- Tag records with `Facet`s for what they are about, and rank on them by passing
  `RetrievalRequest.facets`. Facets rank rather than filter; use
  `records(mentioning:)` when only tagged records will do.
- Use `alias(_:to:in:)` to make two spellings one term — `.values(of: slot)`
  canonicalizes stored values, `.query` expands query text.
- `forget(_:)` propagates to everything derived from a record. Call
  `forgetPreview(_:)` first; the closure reaches further than the selection.

## CLI And REPL

- Build/run with `make run ARGS="..."`; `make run ARGS="repl --database app.db"`
  opens an initial default database.
- In the REPL, use `database open <path>` once, then omit `--database`.
- Use `match --param name=value` for scalar query parameters. With an explicit
  `--database`, `match` opens read-only and will not create a missing database.

## Platform And Maintenance

- On macOS, `make build`/`make test` rebuild the static XCFramework under
  `Artifacts/`. On Linux, those targets build an installed shared library under
  `Artifacts/lattice-linux` and supply `PKG_CONFIG_PATH` to SwiftPM.
- `Native/LatticeDB.lock` pins the upstream release and commit. Native builds
  verify both vendored C headers against that exact source and emit artifact
  provenance. Run `make check-upstream` to discover new releases; update the
  lock with `make update-native VERSION=x.y.z` only as a deliberate upgrade.
- Read `PROJECT.md` before changing target wiring, memory ownership in the C
  bridge, or the native distribution flow.
- `make docs` and `make docs-memory` build the two DocC archives with warnings
  as errors. Renaming a public type without updating the catalog fails them.
