// A database query opens its own read-only transaction, so it does not see
// uncommitted writes. A transaction query does.
try database.write { transaction in
  let ada = try transaction.createNode(.person)
  try transaction.setProperty(Person.name, onNode: ada, to: "Ada Chen")

  let inside = try transaction.match("MATCH (p:Person) RETURN p.name AS name")
  print(inside.count)  // 1

  // Point lookups need no query at all.
  let handle = transaction.node(ada, as: Person.self)
  try handle.set(Person.age, 37)
  print(try handle[Person.name] as Any)  // Optional("Ada Chen")
}
