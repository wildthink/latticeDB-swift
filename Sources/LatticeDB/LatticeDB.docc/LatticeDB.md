# ``LatticeDB``

An embedded property-graph database for Swift, with Cypher queries and ACID transactions.

## Overview

LatticeDB stores a *property graph*: nodes joined by typed, directed edges, both
carrying scalar properties. The whole graph lives in a single file on disk, in
the same process as your app — there is no server to run and no connection to
manage.

The Swift layer is a thin, safe wrapper over the pinned native engine. Open a
``Database``, scope your work in a ``Database/read(_:)`` or
``Database/write(_:)`` closure, and query with ``Database/matchJSON(_:parameters:)``.

```swift
let database = try Database(path: "social.db")

try database.write { transaction in
  let ada = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: ada, to: .string("Ada Chen"))
}

let rows = try database.matchJSON("MATCH (p:Person) RETURN p.name")
```

New to graph databases? Start with <doc:GraphBasics>, then follow
<doc:/tutorials/BuildAGraph>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:GraphBasics>
- <doc:/tutorials/BuildAGraph>
- ``Database``
- ``DatabaseConfiguration``

### Reading and Writing

- <doc:Transactions>
- ``Transaction``
- ``NodeID``
- ``EdgeID``
- ``Value``

### Querying

- <doc:CypherAndJSON>
- ``Database/matchJSON(_:parameters:)``
- ``Database/nodeTypes()``
- ``Database/nodeSummaryJSON(_:)``

### Schema Validation

- <doc:ModelingWithSchema>
- ``GraphSchema``
- ``NodeSchema``
- ``EdgeSchema``
- ``PropertyRule``
- ``ValueKind``

### Temporal Data

- <doc:TemporalGraphs>
- ``TemporalValidity``
- ``TemporalAsOf``

### Indexes

- <doc:IndexingAndPerformance>
- ``Database/createNodeIndex(label:property:)``
- ``Database/dropNodeIndex(label:property:)``
- ``Database/createEdgeIndex(type:property:)``
- ``Database/dropEdgeIndex(type:property:)``

### Command Line

- <doc:CommandLineTool>

### Errors

- ``LatticeError``
- ``SchemaValidationError``
- ``TemporalValidityError``
- ``TemporalQueryError``

### Native Runtime

- ``LatticeDB/LatticeDB``
