// Every `WHERE person.name = ...` above scans the Person nodes.
// An equality index turns that scan into a lookup.
try database.createNodeIndex(label: "Person", property: "name")

// The query text does not change — only its cost.
let rows = try database.matchJSON(
  "MATCH (person:Person) WHERE person.name = $name RETURN person.role",
  parameters: ["name": .string("Ada Chen")]
)

// Indexes persist in the file. Drop one when it stops paying for itself.
try database.dropNodeIndex(label: "Person", property: "name")
