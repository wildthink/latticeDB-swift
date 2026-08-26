# Indexing and Performance

When an index earns its keep, and when it does not.

## Overview

Without an index, a query filtering on a property inspects every candidate node
or edge. An equality index turns that scan into a direct lookup.

```swift
try database.createNodeIndex(label: "Person", property: "email")
try database.createEdgeIndex(type: "ATTENDS", property: "rsvp")
```

Indexes are a property of the database, not of a transaction, and persist in the
file. Creating one that already exists is harmless. Drop with
``Database/dropNodeIndex(label:property:)`` and
``Database/dropEdgeIndex(type:property:)``.

### What they help

These are **equality** indexes. They speed up predicates of the shape
`p.email = $email` for nodes carrying the indexed label, or the edge equivalent.

They do not help range comparisons (`<`, `>`, the valid-time predicates in
<doc:TemporalGraphs>), substring or prefix matching, or filters on a property of
a *different* label than the one indexed.

### When to skip one

An index costs write throughput and file size, so it should pay for itself:

- **Low cardinality.** Indexing a Boolean or a three-value status rarely beats a
  scan — most rows match anyway.
- **Write-heavy, rarely queried.** Every insert and property update maintains
  the index.
- **Small labels.** A few thousand nodes scan fast; measure before adding one.

The clear wins are lookup keys — an email, a slug, an external identifier —
where one value selects one node out of many.

### Writing queries that traverse well

- **Anchor, then traverse.** Start the pattern at the most selective point (an
  indexed property, a small label) and let the edges narrow the rest. Traversal
  cost tracks the edges actually walked, so a good anchor is worth more than any
  index.
- **Return only what you need.** `RETURN p.name` beats `RETURN p`; every column
  is serialized into the JSON result.
- **Batch writes.** One ``Database/write(_:)`` around a thousand nodes is one
  commit; a thousand `write` calls are a thousand commits, and the difference is
  usually an order of magnitude.
- **Use `read` for reads.** It states intent and lets the engine serve
  concurrent readers.
- **Prefer the direct API for point lookups.**
  ``Transaction/nodeIDs(label:)`` and ``Transaction/edgesJSON(for:outgoing:type:)``
  skip query planning entirely.

### Measuring

There is no query plan output. Time the call, vary one thing, and compare —
build a representative database first, since an index changes nothing on a
graph small enough to fit in cache.

## See Also

- <doc:CypherAndJSON>
- ``Database/createNodeIndex(label:property:)``
