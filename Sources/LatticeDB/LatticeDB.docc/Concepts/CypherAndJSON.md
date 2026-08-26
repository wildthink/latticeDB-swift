# Queries and Results

Read the graph with Cypher, and turn the JSON that comes back into Swift values.

## Overview

``Database/matchJSON(_:parameters:)`` runs a read-only Cypher query and returns
its rows as a JSON string — an array of objects, one per row, keyed by the
`RETURN` expressions.

```swift
let json = try database.matchJSON("MATCH (p:Person) RETURN p.name")
// [{"p.name":"Ada Chen"},{"p.name":"Ben Ortiz"}]
```

Queries that can write are rejected. Mutations go through
``Database/write(_:)`` and the ``Transaction`` methods.

## Cypher in five patterns

If you have never written Cypher, these cover nearly everything you will need.
The syntax is a drawing of the pattern you want to find: parentheses are nodes,
square brackets in arrows are edges.

| Pattern | Meaning |
| --- | --- |
| `MATCH (p:Person)` | every node labeled `Person`, bound to `p` |
| `-[:KNOWS]->` | follow an outgoing `KNOWS` edge |
| `<-[:KNOWS]-` | follow an incoming one; `-[r]-` ignores direction and binds the edge to `r` |
| `WHERE p.name = $name` | filter, with `$name` supplied as a parameter |
| `RETURN p.name, e.date` | choose the columns of the result |

Chain hops to traverse further, and name the variables you want back:

```
MATCH (ada:Person)-[:KNOWS]->(friend:Person)-[:ATTENDS]->(event:Event)
WHERE ada.name = $name
RETURN friend.name, event.name, event.date
```

### Bind parameters, never interpolate

Pass values through `parameters`. Names omit the `$` that Cypher uses at the
call site.

```swift
let json = try database.matchJSON(
  "MATCH (p:Person) WHERE p.name = $name RETURN p.name, p.role",
  parameters: ["name": .string("Ada Chen")]
)
```

String-interpolating a value into the query text instead is both a correctness
hazard (quotes and backslashes in the data) and an injection hazard when the
value came from outside your program. Parameters are also the only way to bind
a ``Value/null`` cleanly.

### Decoding results

The return type is a `String` rather than typed rows because the column set is
determined by the query, not by the schema. Decode it with `Codable`, using
`CodingKeys` to map dotted Cypher column names onto Swift properties:

```swift
struct PersonRow: Decodable {
  let name: String
  let role: String?

  enum CodingKeys: String, CodingKey {
    case name = "p.name"
    case role = "p.role"
  }
}

let rows = try JSONDecoder().decode(
  [PersonRow].self,
  from: Data(try database.matchJSON("MATCH (p:Person) RETURN p.name, p.role").utf8)
)
```

Aliasing the columns in Cypher — `RETURN p.name AS name` — keeps the keys plain
and lets you drop `CodingKeys` entirely.

## Reading without Cypher

For simple lookups the transaction API is more direct than a query, and it
works inside a write transaction where `matchJSON` does not:

- ``Transaction/nodeIDs(label:)`` — every node with a label
- ``Transaction/labels(of:)`` — a node's labels
- ``Transaction/nodePropertyJSON(_:of:)`` — one property, JSON-encoded
- ``Transaction/edgesJSON(for:outgoing:type:)`` — a node's edges in one direction
- ``Database/nodeSummaryJSON(_:)`` — a node's labels plus both edge directions
- ``Database/nodeTypes()`` — every label currently in use

## See Also

- <doc:GraphBasics>
- <doc:IndexingAndPerformance>
- ``Database/matchJSON(_:parameters:)``
