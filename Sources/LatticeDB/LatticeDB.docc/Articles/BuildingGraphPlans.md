# Building Graph Plans Directly

Construct a ``GraphPlan`` from specifications when your graph declaration comes
from data rather than a result-builder body.

## Overview

<doc:DeclarativeGraphs> is the most expressive way to write a graph by hand:
use `Node`, `Edge`, and the `@GraphBuilder` result builder. The same plan model
is also public at a lower level. ``NodeSpec``, ``EdgeSpec``,
``GraphMutation``, and ``GraphElement`` let an importer, generator, or library
construct exactly the declarations it needs without synthesizing a builder
closure.

Both forms produce a ``GraphPlan``. Building the plan does not touch a
database; validate it with ``GraphPlan/validate(with:)`` or apply it later with
``GraphPlan/apply(in:schema:mergeStrategy:)``.

## Construct specifications

Create node and edge specifications, then place them in a plan in their
declaration order. A ``NodeTarget/spec(_:)`` connects an edge to a node that
the same plan declares.

```swift
let ada = NodeSpec(
  labels: ["Person"],
  properties: [Property("name", .string("Ada Chen"))]
)
let cafe = NodeSpec(
  labels: ["Place"],
  properties: [Property("name", .string("River Cafe"))]
)
let frequents = EdgeSpec(
  type: "FREQUENTS",
  source: .spec(ada),
  target: .spec(cafe),
  properties: [Property("since", .integer(2019))]
)

let plan = GraphPlan(elements: [
  .node(ada),
  .node(cafe),
  .edge(frequents),
])
```

The convenience ``Edge(_:from:to:properties:)-(EdgeType,_,_,_)`` function accepts a
``NodeSpec`` directly because it conforms to ``NodeReference``. Use it when
only some of a programmatically-created plan needs the shorter spelling:

```swift
let frequents = Edge("FREQUENTS", from: ada, to: cafe) {
  Property("since", .integer(2019))
}
```

Every `NodeSpec` owns a ``NodeRef`` identity token. Copies retain that token,
so repeated references resolve to the same node when the plan is applied.
``GraphApplyResult`` uses the same token to report the resulting identifier.

```swift
let result = try database.write { transaction in
  try plan.apply(in: transaction)
}
let adaID = result[ada]  // NodeID?
```

## Refer to existing nodes

Use ``NodeTarget/id(_:)`` for a node that is already in the database. To
declare changes to that node as a ``NodeSpec``, use
``NodeIdentity/existing(_:)``. Its labels and properties are applied to the
existing node; it never creates a replacement.

```swift
let customer = NodeSpec(
  labels: ["Customer"],
  properties: [Property("tier", .string("gold"))],
  identity: .existing(adaID)
)
let plan = GraphPlan(elements: [
  .node(customer),
  .mutation(.deleteEdge("FREQUENTS", source: .id(adaID), target: .id(cafeID))),
])
```

``GraphMutation`` also exposes direct label and node deletion operations. The
high-level `AddLabel`, `RemoveLabel`, `Delete`, and `Disconnect` functions
create these same mutations.

## Merge and reuse edges

Set a node's identity to ``NodeIdentity/merge(property:value:)`` to reuse the
node whose primary label and property match. The default ``MergeStrategy``
requires an equality index; supply ``MergeStrategy/scanIfUnindexed`` only when
a full label scan is appropriate. Set an edge's identity to
``EdgeIdentity/merge`` to reuse an edge of the same type between the resolved
endpoints.

```swift
let ada = NodeSpec(
  labels: ["Person"],
  properties: [Property("name", .string("Ada Chen"))],
  identity: .merge(property: "email", value: .string("ada@example.com"))
)
```

For a merge, the first item in ``NodeSpec/labels`` is the label used to find a
supporting index and match the node. A plan with no label cannot merge and
throws ``GraphPlanError/mergeRequiresLabel(property:)``.

## Generate plans from data

The direct API is useful when an input collection determines the plan's
elements. Keep the plan a value until the import is ready to commit.

```swift
func peoplePlan(_ names: [String]) -> GraphPlan {
  GraphPlan(elements: names.map { name in
    .node(NodeSpec(
      labels: ["Person"],
      properties: [Property("name", .string(name))]
    ))
  })
}

let plan = peoplePlan(["Ada Chen", "Bo Lin"])
try plan.validate(with: schema)
try database.write { try plan.apply(in: $0) }
```

Use ``GraphPlan/appending(_:)`` to join independently-generated plans. For a
reusable declaration written in the builder style, prefer ``GraphComponent``;
it can be included directly in another `GraphPlan` builder.

## See Also

- <doc:DeclarativeGraphs>
- ``GraphPlan``
- ``GraphBuilder``
- ``GraphComponent``
