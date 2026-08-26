# Graph Basics

The four ideas you need before writing any LatticeDB code.

## Overview

If you have modeled data in SQL, everything here has a familiar counterpart —
the difference is where the relationships live. In a relational database a
relationship is a value (a foreign key) that you rediscover with a join. In a
property graph a relationship is a stored object with its own identity, so
following it is a pointer hop rather than a lookup.

![A small property graph: three Person nodes joined by KNOWS edges, with edges to Place and Event nodes.](graph-basics)

### Nodes

A node is one entity: a person, a place, an order. Creating one returns a
``NodeID`` — a `UInt64` assigned by the database and stable for the node's
lifetime.

```swift
let ada = try transaction.createNode(label: "Person")
```

### Labels

A label classifies a node. It is roughly a table name, with one important
difference: a node may carry several labels at once, and may gain or lose them
over time via ``Transaction/addLabel(_:to:)`` and
``Transaction/removeLabel(_:from:)``. A node with no label is legal.

Labels are how you find nodes without a query — ``Transaction/nodeIDs(label:)``
returns every node carrying one.

### Edges

An edge connects a source node to a target node and has a *type* — by
convention an upper-case verb such as `KNOWS` or `HAPPENS_AT`. Edges are
directed, and direction is part of their identity: `(ada)-[:KNOWS]->(ben)` is
not the same edge as `(ben)-[:KNOWS]->(ada)`. If a relationship is genuinely
mutual, either create both edges or ignore direction when you query.

```swift
let edge = try transaction.createEdge(from: ada, to: ben, type: "KNOWS")
```

An edge is identified by the triple `(source, target, type)` — that is what
``Transaction/deleteEdge(from:to:type:)`` takes.

### Properties

Both nodes and edges hold properties: named scalars of type ``Value``, which is
one of `null`, `bool`, `integer`, `double`, or `string`. There are no nested
objects or arrays; model structure as more nodes and edges instead.

```swift
try transaction.setProperty("name", onNode: ada, to: .string("Ada Chen"))
try transaction.setProperty("since", onEdge: edge, to: .integer(2019))
```

Properties on edges are what make the model expressive — a `RATED` edge can
carry the score, so the rating needs no node of its own.

## Why a graph

The payoff appears when queries traverse several hops. "Who does Ada know, and
which events do *they* attend?" is two joins in SQL and grows a join per hop; in
Cypher it is one pattern, and the cost tracks the number of edges actually
walked rather than the size of the tables.

```
MATCH (ada:Person)-[:KNOWS]->(friend)-[:ATTENDS]->(event)
WHERE ada.name = $name
RETURN friend.name, event.name
```

That is the whole model. Continue with <doc:Transactions> for how reads and
writes are scoped, then <doc:CypherAndJSON> for querying.

## See Also

- <doc:GettingStarted>
- <doc:/tutorials/BuildAGraph>
