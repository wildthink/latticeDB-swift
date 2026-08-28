// A traversal changes which entity the later clauses talk about.
let places = try database.match(Person.self)
  .where(Person.name == "Ada Chen")
  .outgoing(.knows, to: Person.self, as: "friend")
  .outgoing(.frequents, to: Place.self, as: "place")
  .select(Place.name)
  .fetchRows()

// MATCH (v0:Person)-[:KNOWS]->(friend:Person)-[:FREQUENTS]->(place:Place)
// WHERE (v0.name = $p0) RETURN place.name AS name
