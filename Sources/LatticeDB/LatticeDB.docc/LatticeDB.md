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

Model your labels and properties once, and the same work reads as declarations
and typed queries:

```swift
try database.apply {
  Node(.person) { Person.name .= "Ada Chen" }
}

let adults = try database.match(Person.self)
  .where(Person.age >= 21)
  .select(Person.name)
  .fetchRows()
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

### Modeling Types and Keys

- ``NodeType``
- ``EdgeType``
- ``PropertyKey``
- ``PropertyKeys``
- ``GraphNode``
- ``GraphEdge``
- ``ValueRepresentable``

### Declaring Graphs

- <doc:DeclarativeGraphs>
- <doc:BuildingGraphPlans>
- ``GraphPlan``
- ``GraphBuilder``
- ``PropertyBuilder``
- ``GraphComponent``
- ``NodeSpec``
- ``EdgeSpec``
- ``GraphApplyResult``
- ``Database/apply(schema:mergeStrategy:_:)``

### Updating

- ``Database/update(schema:mergeStrategy:_:)``
- ``NodeHandle``
- ``GraphMutation``
- ``MergeStrategy``
- ``NodeIdentity``
- ``EdgeIdentity``

### Querying

- <doc:QueryingAndUpdating>
- <doc:CypherAndJSON>
- ``Query``
- ``Predicate``
- ``Cypher``
- ``Row``
- ``NodeSnapshot``
- ``EdgeSnapshot``
- ``JSONValue``
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
- ``SchemaBuilder``
- ``SchemaRule``

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

### Full-Text Search

- <doc:SearchingAndRanking>
- ``Database/createFullTextIndex(label:property:)``
- ``Database/dropFullTextIndex(label:property:)``
- ``Database/fullTextIndexExists(label:property:)``
- ``Database/createFullTextIndex(edgeType:property:)``
- ``Database/dropFullTextIndex(edgeType:property:)``
- ``Database/fullTextIndexExists(edgeType:property:)``
- ``Database/fullTextSearch(_:label:property:limit:fuzzy:)``
- ``Transaction/fullTextSearch(_:label:property:limit:fuzzy:)``
- ``TextMatch``
- ``FuzzyMatching``

### Vectors and Embeddings

- ``Transaction/setVector(_:forKey:onNode:)``
- ``Database/vectorSearch(_:limit:efSearch:)``
- ``Transaction/vectorSearch(_:limit:efSearch:)``
- ``VectorMatch``
- ``Embedding``
- ``EmbeddingClient``
- ``EmbeddingConfiguration``
- ``EmbeddingAPIFormat``

### Durable Streams

- <doc:DurableStreams>
- ``Transaction/publish(_:to:kind:)``
- ``Database/readStream(_:after:limit:timeout:)``
- ``Database/lastSequence(ofStream:)``
- ``Database/streamOffset(_:consumer:)``
- ``Transaction/setStreamOffset(_:stream:consumer:)``
- ``Transaction/trimStream(_:through:)``
- ``StreamRecord``

### Command Line

- <doc:CommandLineTool>

### Errors

- ``LatticeError``
- ``SchemaValidationError``
- ``GraphPlanError``
- ``QueryError``
- ``CypherError``
- ``TemporalValidityError``
- ``TemporalQueryError``
- ``VectorError``
- ``StreamError``

### Native Runtime

- ``LatticeDB/LatticeDB``
