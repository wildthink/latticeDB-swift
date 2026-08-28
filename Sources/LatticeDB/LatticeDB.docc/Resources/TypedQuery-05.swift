// Writing the query yourself: interpolated values become bound parameters.
let name = "Ada Chen"
let rows = try database.match(
  "MATCH (p:\(NodeType.person)) WHERE p.name = \(name) RETURN p.name AS name"
)
// text:       MATCH (p:Person) WHERE p.name = $p0 RETURN p.name AS name
// parameters: ["p0": .string("Ada Chen")]

// A hostile value stays a value; it cannot change the shape of the query.
let hostile = "\") RETURN 1 //"
let safe = try database.match("MATCH (p:Person) WHERE p.name = \(hostile) RETURN p")
