# LatticeDB for Swift

One Swift package provides an embeddable `LatticeDB` library and a `lattice`
command-line tool. The public Swift layer is intentionally separate from the
native distribution mechanism.

Apple consumers statically link the `liblattice.a` within
`Artifacts/Lattice.xcframework`. The `Makefile` builds or refreshes that artifact
from an upstream LatticeDB checkout:

```sh
make native
make test
make run ARGS="version"
```

The first native build clones the upstream source to `.native/latticedb`. Set
`LATTICE_SOURCE` to use an existing source checkout instead.

Linux Swift-server applications use the same `LatticeDB` product. Install the
upstream library and expose its generated `lattice.pc` through `PKG_CONFIG_PATH`:

```sh
zig build --prefix /opt/lattice
export PKG_CONFIG_PATH=/opt/lattice/lib/pkgconfig
swift build
```

The upstream C ABI header is vendored at `Sources/CLattice/include/lattice.h`.
When updating the native artifact, update that header from the same LatticeDB
release before publishing the Swift package.

## REPL

The REPL keeps one default database open for the session. Open or create it
once, then omit `--database` from graph commands:

```text
lattice > database open demo.db
lattice > node create --label Person
lattice > edge create --source 1 --target 2 --type KNOWS
lattice > node list --label Person
lattice > node show 1
lattice > node labels 1
lattice > edge delete --source 1 --target 2 --type KNOWS
```

Open or create the initial database directly when starting the shell:

```sh
swift run lattice repl --database Examples/people-places-events.db
```

Pass `--database path.db` to any command to use a one-off database instead.

## Native Queries

`match` accepts LatticeDB's native Cypher syntax and emits JSON rows:

```text
lattice > match 'MATCH (n:Person) RETURN n.name'
```

Use `--format table` for interactive display or `--format csv` for shell data
workflows. JSON remains the default.

For repeatable queries, pass a UTF-8 file instead of inline Cypher:

```sh
swift run lattice match --database Examples/people-places-events.db --file Examples/people-names.cypher --format table
```

## Indexes

Create equality indexes before frequently filtering by a property:

```sh
swift run lattice index node create --database demo.db --label Person --property name
swift run lattice index edge create --database demo.db --type KNOWS --property since
```

## Demo

Create a small people, places, and events graph for experimentation:

```sh
swift run lattice demo
swift run lattice repl
```

Then run the native Cypher examples in `Examples/queries.cypher` from the REPL.

Use `node types` to list labels actually present in a database. The native
Cypher engine does not currently return labels through `labels(n)`.

## Properties

Set properties using explicit types, or let the CLI infer unambiguous values.
Leading-zero numeric values remain strings unless `--type int` is supplied.

```text
lattice > node set 1 visits --value 12
lattice > node set 1 postal_code --value 00123
lattice > node set 1 postal_code --value 00123 --type int
```
