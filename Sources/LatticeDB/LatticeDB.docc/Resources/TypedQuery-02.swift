// Read `cypher` to see exactly what will run. No database needed.
let query = Query(Person.self)
  .where(Person.age >= 21)
  .and(Person.name.hasPrefix("A"))
  .select(Person.name)

print(query.cypher.text)
// MATCH (v0:Person) WHERE (v0.age >= $p0) AND (v0.name STARTS WITH $p1) RETURN v0.name AS name
print(query.cypher.parameters)
// ["p0": .integer(21), "p1": .string("A")]
