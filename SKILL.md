---
name: latticedb-swift
description: Use the LatticeDB Swift package to embed a property graph, run parameterized native Cypher queries, or operate its CLI and REPL. Use when Swift code needs local graph storage; do not use for remote graph services or historical database snapshots.
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
- The C ABI header and native artifact must come from the same upstream
  LatticeDB release. When updating upstream, refresh both and run `make test`.
- Read `PROJECT.md` before changing target wiring, memory ownership in the C
  bridge, or the native distribution flow.
