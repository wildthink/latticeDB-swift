// An upsert reuses the node whose indexed property matches.
try database.createNodeIndex(label: "Person", property: "name")

try database.update {
  Upsert(.person, matching: Person.name, "Ada Chen") {
    Person.age .= 38
  }
  Connect(.frequents, from: adaID, to: cafeID)
  AddLabel(.customer, to: adaID)
  Delete(node: staleID)
}

// Without the index, the upsert throws instead of scanning every Person:
// GraphPlanError.indexRequired(label: "Person", property: "name")
