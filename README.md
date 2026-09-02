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

## Documentation

The Swift API, articles, and a two-chapter tutorial live in the DocC catalog at
`Sources/LatticeDB/LatticeDB.docc`.

```sh
make docs           # build the archive into .build/documentation
make docs-preview   # serve it locally
```

`make docs` treats documentation warnings as errors, so a broken symbol link or
malformed directive fails the build. The archive contains the `LatticeDB` target
alone.

`swift-docc-plugin` is only added to the package when `LATTICE_DOCS` is set,
which the docs targets do for themselves. Ordinary builds — and anything that
depends on LatticeDB — never resolve the plugin or SymbolKit. The docs targets
also restore `Package.resolved` afterwards, so the committed lock keeps
describing the dependency set consumers actually get.

In Xcode, use **Product > Build Documentation** with the `LatticeDB-Docs`
scheme selected. The default `LatticeDB-Package` scheme documents every
dependency as well — ArgumentParser, LineEditor, and the rest — because Xcode
builds documentation for everything the scheme builds.

## Native Version

The pinned upstream repository, tag, version, and immutable commit are tracked
in [`Native/LatticeDB.lock`](Native/LatticeDB.lock). Every native build verifies
that both vendored C headers exactly match that source revision, then writes an
ignored `Provenance.json` alongside the generated artifact. It records the
LatticeDB version and revision, header SHA-256, Zig version, build time, and
target set.

```sh
make verify-native
make check-upstream
```

`check-upstream` only reports a newer release. To prepare an intentional
upgrade, provide the exact release you reviewed:

```sh
make update-native VERSION=0.12.0
make verify-native
make test
```

`update-native` updates the local upstream checkout, lock, both vendored
headers, and `LatticeDB.nativeVersion`. It does not commit, so review the
upstream release notes and the resulting diff before making the upgrade final.

Linux Swift-server applications use the same `LatticeDB` product. Install the
upstream library and expose its generated `lattice.pc` through `PKG_CONFIG_PATH`.
On Linux, the package's Makefile does this automatically and installs the native
library under `Artifacts/lattice-linux`:

```sh
make build
make test
```

macOS always links the pinned static XCFramework, not a Homebrew installation.

For an application that consumes this package directly, build the upstream
shared library into a stable prefix first:

```sh
zig build --prefix /opt/lattice -Doptimize=ReleaseSafe
export PKG_CONFIG_PATH=/opt/lattice/lib/pkgconfig
swift build
```

`lattice.pc` adds the installed library directory as a runtime search path. Use
`make native-linux LATTICE_ZIG_TARGET=aarch64-linux-gnu` to cross-build a native
prefix; run `make linux-test` only on a Linux host for the matching architecture.

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

Bind scalar values instead of interpolating user input into Cypher. Repeat
`--param name=value`; values use the same unambiguous inference as properties:

```sh
swift run lattice match --database Examples/people-places-events.db \
  --param name='Ada Chen' 'MATCH (person:Person) WHERE person.name = $name RETURN person'
```

When `match` receives `--database`, it opens that database read-only and will
not create a missing file. Use `database open` or a write command to create one.

## Schema And Valid Time

`GraphSchema` is opt-in validation rather than a storage-level constraint. It
validates a complete property dictionary before a helper creates a node or edge,
so applications can adopt types and required fields without losing LatticeDB's
schema-flexible core:

```swift
let schema = GraphSchema(nodes: [
    NodeSchema(label: "Person", properties: ["name": .init(kind: .string, required: true)])
])
try database.write { transaction in
    try schema.createNode(in: transaction, label: "Person", properties: ["name": .string("Ada")])
}
```

`TemporalValidity` is also opt-in. It writes `validFrom` and `validTo` epoch
millisecond properties and uses an exclusive end time, which can be passed to
parameterized Cypher queries. It qualifies current data; it is not a native
historical snapshot or a true database `as-of` transaction.

`TemporalAsOf` builds that predicate and binding safely:

```swift
let asOf = try TemporalAsOf(date: Date())
let predicate = try asOf.predicate(for: "person")
let rows = try database.matchJSON(
    "MATCH (person:Person) WHERE \(predicate) RETURN person",
    parameters: asOf.parameters
)
```

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

## Search And Streams

Beyond the property graph, the package exposes three native subsystems. All
three are ordinary database features with no dependency on any particular
application; see the `Searching and Ranking` and `Durable Streams` articles in
the DocC catalog.

Full-text search is BM25-scored over an explicitly declared index. Searching a
label and property with no index fails rather than returning nothing, so a
mistyped property name cannot be mistaken for a genuine miss:

```swift
try database.createFullTextIndex(label: "Article", property: "body")
let matches = try database.fullTextSearch("kiln", label: "Article", property: "body")
```

Vector search is off unless the database is opened with a stored width, which is
then recorded in the file. `Embedding.hash` produces deterministic vectors with
no external service; `EmbeddingClient` calls an OpenAI- or Ollama-shaped
endpoint:

```swift
let database = try Database(path: path, configuration: .init(vectorDimensions: 768))
try database.write { try $0.setVector(embedding, forKey: "embedding", onNode: article) }
let neighbors = try database.vectorSearch(query, limit: 10)
```

Durable streams are an append-only log in the same file. A record published in a
write transaction commits with the graph change that produced it, and consumers
resume from an offset they commit alongside their own work:

```swift
try database.write { transaction in
    try transaction.publish(.string(body), to: "articles.indexed", kind: "created")
}
let records = try database.readStream("articles.indexed", after: cursor, limit: 100)
```
## Evidence And Assertions

The `LatticeMemory` library is a second product in this package. It stores raw
**evidence** that is never rewritten, and **assertions** derived from it that
carry a link back to the evidence — and, where a rule asks for one, the verbatim
quote they were read from.

Nothing in it is specific to any one domain. A slot is a name you choose, a scope
dimension is a name you choose, and the built-in extractor is regular
expressions over text, so the same store suits a configuration history, a
document-extraction pipeline, or a device's derived state.

```swift
import LatticeMemory

let store = try MemoryStore(
    path: "memory.db",
    schema: ["package.manager": SlotRule(allowedValues: ["npm", "pnpm", "yarn"])],
    extractors: [
        PatternExtractor([.init(slot: "package.manager", pattern: #/using (npm|pnpm|yarn)/#)])
    ]
)

try store.record(EvidenceDraft(text: "We are using pnpm.", scope: ["project": "acme"]))
let current = try store.currentAssertions(in: ["project": "acme"])
let lastMarch = try store.assertions(validAt: date, in: ["project": "acme"])
```

Three rules do most of the work. Values are **superseded, not overwritten**, so
`assertions(validAt:in:)` answers what was held to be true at any past moment.
**Scope is checked on every read**: a record is visible only when every dimension
it declares appears in the querying scope with the same value. And **extractors
propose while the store decides** — an extractor has no write access, so one that
names an undeclared slot, invents a quote, or reaches outside its evidence's
scope has its proposal refused and reported rather than stored.
Build its documentation with `make docs-memory`; the articles live in
`Sources/LatticeMemory/LatticeMemory.docc`.
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
