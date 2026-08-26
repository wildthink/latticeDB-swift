# Declaring Graphs

Describe nodes and edges as a value, then write them in one transaction.

## Overview

A ``GraphPlan`` is a declaration of graph shape. Building one runs no code
against the database and needs no transaction, so a plan can be built anywhere,
passed between concurrency domains, inspected in a test, and applied later —
possibly more than once.

```swift
let plan = GraphPlan {
  let ada = Node(.person) {
    Person.name .= "Ada Chen"
    Person.age .= 37
  }
  let cafe = Node(.place) { Place.name .= "River Cafe" }
  Edge(.frequents, from: ada, to: cafe) { Property("since", .integer(2019)) }
}

let result = try database.write { try plan.apply(in: $0) }
```

``Database/apply(schema:mergeStrategy:_:)`` wraps the same thing in its own write
transaction when you do not need one of your own:

```swift
let result = try database.apply {
  let ada = Node(.person) { Person.name .= "Ada Chen" }
  Edge(.knows, from: ada, to: Node(.person) { Person.name .= "Bo Lin" })
}
```

The transaction commits when every declaration has been written and rolls back
if any of them throws, so a plan is all-or-nothing.

## Naming what you declare

A node bound to a `let` inside the builder joins the plan when an edge
references it. A node that stands alone is written as its own statement. Both
spellings resolve through the same identity, so a node named twice is created
once:

```swift
let ada = Node(.person) { Person.name .= "Ada Chen" }

try database.apply {
  ada                                     // written here
  Edge(.knows, from: ada, to: bo)         // resolves to the same node
}
```

``GraphApplyResult`` maps each declaration back to the identifier it produced:

```swift
let adaID = result[ada]        // NodeID?
let edgeIDs = result.edges     // [EdgeID], in declaration order
```

## Extendable types and typed keys

Labels and edge types are ``NodeType`` and ``EdgeType`` — string-backed values
you extend with the vocabulary you model, so call sites read in leading-dot
syntax while unmodeled labels stay expressible as literals:

```swift
extension NodeType { static let person: NodeType = "Person" }
extension EdgeType { static let knows: EdgeType = "KNOWS" }
```

Properties are ``PropertyKey`` values carrying the Swift type stored under them.
Declare an entity, then declare its keys — any module may add more:

```swift
enum Person: GraphNode {
  static let nodeType: NodeType = .person

  static let name = PropertyKey<Person, String>("name")
  static let age = PropertyKey<Person, Int>("age")
}
```

The `.=` operator binds a key to a value of exactly its type; `Property(_:_:)`
is the untyped equivalent for properties you have not modeled. Conform your own
types to ``ValueRepresentable`` to store them — enumerations with a representable
raw value get their conformance for free.

## Control flow

The builder supports `if`, `if let`, `if/else`, `switch`, and `for`, so a plan
can be shaped by data:

```swift
try database.apply {
  for person in imported {
    let node = Node(.person) {
      Person.name .= person.name
      if let age = person.age { Person.age .= age }
    }
    if person.isCustomer { AddLabel(.customer, to: node) }
  }
}
```

## Changing what is already there

Declarations are not limited to new data. `Upsert(_:matching:_:)`
reuses the node whose property matches, `Connect(_:from:to:)`
creates an edge only when it is missing, and the mutation verbs change existing
state:

```swift
try database.createNodeIndex(label: "Person", property: "email")

try database.update {
  Upsert(.person, matching: Person.email, "ada@example.com") {
    Person.name .= "Ada Chen"
  }
  Connect(.knows, from: adaID, to: boID)
  AddLabel(.customer, to: adaID)
  Disconnect(.knows, from: adaID, to: staleID)
  Delete(node: staleID)
}
```

Upsert matches through the explicit equality index for the label and property.
Without that index, applying throws
``GraphPlanError/indexRequired(label:property:)`` naming what is missing rather
than silently scanning every node with the label. Pass
``MergeStrategy/scanIfUnindexed`` when a scan is what you want.

## Validating before writing

Pass a ``GraphSchema`` and every declaration is checked before the first write,
so a validation failure leaves the graph untouched:

```swift
let schema = GraphSchema(
  nodes: [
    NodeSchema(.person, allowsAdditionalProperties: false) {
      Required(Person.name)
      Rule(Person.age)
    }
  ]
)

try database.apply(schema: schema) {
  Node(.person) { Property("nmae", .string("Ada")) }   // throws, writes nothing
}
```

``Required(_:allowsNull:)`` and ``Rule(_:required:allowsNull:)`` take the scalar
kind from the key's Swift type, so the schema and the keys cannot drift apart.

## Reusable fragments

Conform a type to ``GraphComponent`` to package a fragment of declaration and
use it inside any plan:

```swift
struct Neighborhood: GraphComponent {
  let people: [String]

  var body: GraphPlan {
    for name in people {
      Node(.person) { Person.name .= name }
    }
  }
}

try database.apply { Neighborhood(people: ["Ada", "Bo"]) }
```

## See Also

- <doc:BuildingGraphPlans>
- <doc:QueryingAndUpdating>
- <doc:ModelingWithSchema>
- ``GraphPlan``
- ``GraphBuilder``
- ``NodeHandle``
