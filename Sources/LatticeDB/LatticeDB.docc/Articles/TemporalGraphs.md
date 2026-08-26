# Temporal Graphs

Record when a fact was true, and query the graph as it stood at a chosen moment.

## Overview

Some facts have a lifetime: an employment, a lease, a price. ``TemporalValidity``
and ``TemporalAsOf`` model that as *valid time* — an interval stored on the node
or edge as ordinary properties, plus a Cypher predicate that filters on it.

This is an application-level convention, not a storage feature. It qualifies
the graph's current data by application time; it does not roll the database
back to an earlier state.

### Record an interval

``TemporalValidity`` is a half-open interval: `validFrom` is inclusive,
`validTo` is exclusive, and a `nil` `validTo` means "still true". An end before
the start throws ``TemporalValidityError/endBeforeStart``.

```swift
let tenure = try TemporalValidity(
  validFrom: startDate,
  validTo: endDate  // nil for an open interval
)

try database.write { transaction in
  let employment = try transaction.createEdge(from: ada, to: studio, type: "WORKS_AT")
  try transaction.setTemporalValidity(tenure, onEdge: employment)
}
```

``Transaction/setTemporalValidity(_:onEdge:fromKey:toKey:)`` writes the bounds as
epoch-millisecond integers under `validFrom` and `validTo`. Override `fromKey`
and `toKey` when your model already uses other names — pass the same names to
``TemporalAsOf`` later. ``TemporalValidity/contains(_:)`` answers the same
question in memory, without a query.

Model a change by closing the current interval and adding a new edge rather than
overwriting properties; that is what keeps the history queryable.

### Query as of a date

``TemporalAsOf`` produces the predicate and the bound parameter for a given
instant:

```swift
let asOf = try TemporalAsOf(date: someDate)

let json = try database.matchJSON(
  """
  MATCH (person:Person)-[employment:WORKS_AT]->(studio:Studio)
  WHERE \(try asOf.predicate(for: "employment"))
  RETURN person.name, studio.name
  """,
  parameters: asOf.parameters
)
```

``TemporalAsOf/predicate(for:)`` expands to
`employment.validFrom <= $asOf AND (employment.validTo IS NULL OR employment.validTo > $asOf)`,
and ``TemporalAsOf/parameters`` binds `$asOf` to the instant in epoch
milliseconds. Interpolating the *predicate* into the query is safe — every
identifier it contains is validated — while the date itself stays a bound
parameter.

Rename the parameter when a query carries two qualifiers:

```swift
let opened = try TemporalAsOf(date: date, parameter: "openedAt")
```

All four identifiers — `fromKey`, `toKey`, `parameter`, and the `variable`
passed to `predicate(for:)` — must be alphanumeric or `_`. Anything else throws
``TemporalQueryError/invalidIdentifier(_:)``, which is what makes the
interpolation above safe.

### Indexing

Temporal predicates are range comparisons, and node/edge indexes in LatticeDB
are equality indexes — see <doc:IndexingAndPerformance>. Narrow with an indexed
equality (a label, a key) first and let the temporal predicate filter the
remainder.

## See Also

- <doc:CypherAndJSON>
- ``TemporalValidity``
- ``TemporalAsOf``
