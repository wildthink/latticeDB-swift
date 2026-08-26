# Modeling with a Schema

Validate property dictionaries before they reach the graph.

## Overview

LatticeDB does not enforce a schema in storage: any node may carry any property.
``GraphSchema`` is an opt-in, in-memory layer that checks a complete property
dictionary *before* you write it, so a typo becomes a Swift error instead of a
silently orphaned property.

It is advisory. It validates what passes through it and nothing else — data
written by another process, another program version, or the `lattice` CLI is
unaffected.

### Define the shape

```swift
let schema = GraphSchema(
  nodes: [
    NodeSchema(
      label: "Person",
      properties: [
        "name": PropertyRule(kind: .string, required: true),
        "role": PropertyRule(kind: .string),
        "retiredOn": PropertyRule(kind: .string, allowsNull: true),
      ],
      allowsAdditionalProperties: false
    )
  ],
  edges: [
    EdgeSchema(
      type: "ATTENDS",
      properties: ["rsvp": PropertyRule(kind: .bool, required: true)]
    )
  ]
)
```

``PropertyRule`` has three knobs:

- `kind` — the required ``ValueKind`` when the value is non-null.
- `required` — the key must be present in the dictionary. Default `false`.
- `allowsNull` — a present ``Value/null`` satisfies the rule regardless of
  `kind`. Default `false`, so a nullable property must opt in.

`allowsAdditionalProperties` is the open/closed switch. Left at its default
`true`, undeclared properties pass through untouched — useful while a model is
still moving. Set to `false` to reject anything not listed, which is what turns
a misspelled key into an error.

### Create through the schema

``GraphSchema/createNode(in:label:properties:)`` validates, creates the node
with its label, and sets every property in one step:

```swift
try database.write { transaction in
  let ada = try schema.createNode(
    in: transaction,
    label: "Person",
    properties: ["name": .string("Ada Chen"), "role": .string("Urban designer")]
  )

  let salon = try transaction.createNode(label: "Event")

  _ = try schema.createEdge(
    in: transaction,
    from: ada, to: salon,
    type: "ATTENDS",
    properties: ["rsvp": .bool(true)]
  )
}
```

Because validation happens first, a rejected write throws before anything is
created — and even if it did not, the enclosing ``Database/write(_:)`` would
roll the transaction back.

Use ``GraphSchema/validateNode(label:properties:)`` and
``GraphSchema/validateEdge(type:properties:)`` directly when you want to check a
dictionary — say, at the edge of an import — without writing it.

### Validation is whole-dictionary

The schema validates the dictionary you hand it, so it can only enforce
`required` on a complete set of properties. Incremental updates through
`Transaction.setProperty(_:onNode:to:)` bypass it entirely. Where that matters,
build the full dictionary and route it through the schema.

### Errors

| ``SchemaValidationError`` | Cause | Fix |
| --- | --- | --- |
| `unknownNodeLabel` | No ``NodeSchema`` for that label | Add one, or use ``Transaction/createNode(label:)`` directly |
| `unknownEdgeType` | No ``EdgeSchema`` for that type | Add one, or create the edge directly |
| `missingRequiredProperty` | A `required` key is absent | Supply it, or drop `required` |
| `unexpectedProperty` | Undeclared key on a closed schema | Declare it, or set `allowsAdditionalProperties: true` |
| `invalidPropertyType` | Kind mismatch; carries `expected` and `actual` | Fix the value, or widen the rule |

Each case names the offending entity and property, so the error is usually
enough to locate the bug without a debugger.

## See Also

- <doc:GraphBasics>
- ``GraphSchema``
- ``PropertyRule``
