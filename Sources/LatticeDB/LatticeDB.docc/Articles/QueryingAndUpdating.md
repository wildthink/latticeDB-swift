# Querying and Updating

Read the graph with typed queries, and write it through declarations.

## Overview

Reads and writes in LatticeDB are deliberately asymmetric. Reads may go through
native Cypher; writes never do, because the bridge rejects any query that
writes. Everything that changes the graph goes through a ``GraphPlan`` or the
``Transaction`` methods, which is why the query API below is read-only.

There are three layers of reading, each usable on its own and each built on the
one below:

| Layer | Use it when |
| --- | --- |
| ``Query`` | the shape is a pattern over modeled entities |
| ``Cypher`` and `Database.match(_:)` | you want to write the query yourself |
| ``Database/matchJSON(_:parameters:)`` | you want the raw JSON |

## Typed queries

`Database.match(_:)` starts a query rooted at a modeled entity. Nothing runs
until you fetch:

```swift
let adults = try database.match(Person.self)
  .where(Person.age >= 21)
  .and(Person.name.hasPrefix("A"))
  .select(Person.name)
  .orderBy(Person.name)
  .limit(10)
  .fetchRows()
```

Comparison operators on a ``PropertyKey`` build a ``Predicate``, and `&&`, `||`,
and `!` compose them. The value side is typed by the key, so `Person.age >= 21`
compiles and `Person.age >= "21"` does not. Every literal becomes a bound
parameter — no value ever reaches the query as text.

A traversal moves the entity the later clauses talk about:

```swift
let places = try database.match(Person.self)
  .where(Person.name == "Ada Chen")
  .outgoing(.knows, to: Person.self, as: "friend")
  .outgoing(.frequents, to: Place.self, as: "place")
  .select(Place.name)
  .fetchRows()
```

Fetch in the shape you need: ``Query/fetchRows()`` for ``Row`` values,
``Query/fetch(as:)`` to decode each row into a `Decodable` type,
``Query/fetchIDs()`` for the identifiers of the matched nodes, and
``Query/count()`` for how many rows the pattern matches.

Read ``Query/cypher`` to see exactly what will run, with its parameters. That is
the cheapest way to test a query, because it needs no database:

```swift
Query(Person.self).where(Person.age >= 21).select(Person.name).cypher.text
// MATCH (v0:Person) WHERE (v0.age >= $p0) RETURN v0.name AS name
```

### Key-path shorthand

Where the API already knows the entity, keys can be written as key paths. Add a
forwarding member on ``PropertyKeys`` for each key you want to spell that way:

```swift
extension PropertyKeys where Owner == Person {
  var name: PropertyKey<Person, String> { Person.name }
  var age: PropertyKey<Person, Int> { Person.age }
}

try database.match(Person.self).where(\.age, .greaterThanOrEqual, 21).select(\.name)
```

## Writing Cypher yourself

``Cypher`` is a query built with string interpolation, where interpolated values
become bound parameters:

```swift
let rows = try database.match(
  "MATCH (p:\(NodeType.person)) WHERE p.name = \(name) RETURN p.name AS name"
)
// text:       MATCH (p:Person) WHERE p.name = $p0 RETURN p.name AS name
// parameters: ["p0": .string(name)]
```

Interpolating a ``NodeType``, an ``EdgeType``, or a ``PropertyKey`` splices a
validated identifier. Splicing arbitrary text needs the explicit `\(raw:)` form,
which is the only spelling that can change the shape of a query and is therefore
easy to review and to search for. An invalid identifier is reported when the
query runs, not silently dropped.

Results decode through ``Row``:

```swift
struct Summary: Decodable { let name: String; let age: Int }

let people = try database.match(
  "MATCH (p:Person) RETURN p.name AS name, p.age AS age", as: Summary.self)

let total = try database.matchCount("MATCH (p:Person) RETURN count(p) AS total")
let first = try database.matchScalar("MATCH (p:Person) RETURN p.name AS name", as: String.self)
```

Note that `RETURN p` returns a node's identifier, not its properties. Return the
properties you want — `RETURN p.name AS name` — or use ``Query/fetchIDs()`` and
read the node through the transaction API.

## Reading inside a write

`Database.match(_:)` opens its own read-only transaction, so it does not see
writes that the enclosing ``Database/write(_:)`` block has not committed yet.
When you need to query what you just wrote, use the transaction's own query:

```swift
try database.write { transaction in
  let ada = try transaction.createNode(.person)
  try transaction.setProperty(Person.name, onNode: ada, to: "Ada Chen")

  let rows = try transaction.match("MATCH (p:Person) RETURN p.name AS name")  // sees Ada
}
```

## Reading without a query

For point lookups the transaction API is more direct:

```swift
try database.read { transaction in
  let name = try transaction.property(Person.name, ofNode: ada)     // String?
  let labels = try transaction.nodeTypes(of: ada)                   // [NodeType]
  let edges = try transaction.edges(for: ada, outgoing: true, type: .knows)
  let friends = try transaction.neighbors(of: ada, type: .knows)    // [NodeID]
}
```

An unset property reads as `nil` — the engine reports it as not found, which is
not an error here. ``EdgeSnapshot`` carries the stable edge identifier, which is
what edge properties are keyed by:

```swift
let since = try transaction.propertyValue("since", ofEdge: edges[0].id)
```

## Read-modify-write

``NodeHandle`` is a typed cursor over one node, for work that reads a value and
writes it back:

```swift
try database.write { transaction in
  let ada = transaction.node(adaID, as: Person.self)
  let age = try ada[Person.age] ?? 0
  try ada.set(Person.age, age + 1)
  try ada.addLabel(.customer)
}
```

## Updating

Writes are declarations. See <doc:DeclarativeGraphs> for the full picture; in
short:

```swift
try database.update {
  Upsert(.person, matching: Person.email, "ada@example.com") {
    Person.name .= "Ada Chen"
  }
  Connect(.knows, from: adaID, to: boID)
  Delete(node: staleID)
}
```

## See Also

- <doc:DeclarativeGraphs>
- <doc:CypherAndJSON>
- <doc:IndexingAndPerformance>
- ``Query``
- ``Cypher``
- ``Row``
