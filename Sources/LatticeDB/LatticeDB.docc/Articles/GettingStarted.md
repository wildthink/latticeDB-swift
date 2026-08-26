# Getting Started

Add the package, write a few nodes, and query them back.

## Overview

### Add the dependency

```swift
.package(url: "https://github.com/wildthink/LatticeDB.git", from: "0.1.0"),
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "LatticeDB", package: "LatticeDB")])
```

The native engine ships with the package: macOS links a pinned static
XCFramework, and Linux links an installed LatticeDB prefix found through
`lattice.pc`. ``LatticeDB/LatticeDB/nativeVersion`` reports the engine version
in use.

### Open a database

```swift
import LatticeDB

let database = try Database(path: "social.db")
```

The file is created if it does not exist. To require an existing file, or to
forbid writes through this handle, pass a ``DatabaseConfiguration``:

```swift
let database = try Database(
  path: "social.db",
  configuration: .init(createIfMissing: false, readOnly: true)
)
```

Keep the ``Database`` alive for as long as you need the graph; it closes its
native handle when released.

### Write

```swift
let ids = try database.write { transaction in
  let ada = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: ada, to: .string("Ada Chen"))

  let cafe = try transaction.createNode(label: "Place")
  try transaction.setProperty("name", onNode: cafe, to: .string("River Cafe"))

  let visits = try transaction.createEdge(from: ada, to: cafe, type: "FREQUENTS")
  try transaction.setProperty("since", onEdge: visits, to: .integer(2019))

  return (ada, cafe)
}
```

The closure commits on return and rolls back if it throws — see
<doc:Transactions>.

### Query

```swift
let json = try database.matchJSON(
  "MATCH (p:Person)-[:FREQUENTS]->(place) WHERE p.name = $name RETURN place.name",
  parameters: ["name": .string("Ada Chen")]
)
// [{"place.name":"River Cafe"}]
```

### Read directly

For point lookups, skip Cypher:

```swift
try database.read { transaction in
  let people = try transaction.nodeIDs(label: "Person")
  let labels = try transaction.labels(of: ids.0)
  let name = try transaction.nodePropertyJSON("name", of: ids.0)  // "\"Ada Chen\""
}
```

### Next

- <doc:GraphBasics> — nodes, labels, edges, and properties from scratch
- <doc:/tutorials/BuildAGraph> — build and query a real graph step by step
- <doc:CommandLineTool> — inspect the same file from a terminal
