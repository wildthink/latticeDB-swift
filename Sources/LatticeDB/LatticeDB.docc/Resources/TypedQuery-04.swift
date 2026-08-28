struct Summary: Decodable {
  let name: String
  let age: Int
}

// Decode rows into a Swift type...
let people = try database.match(Person.self)
  .select(Person.name)
  .select(Person.age)
  .fetch(as: Summary.self)

// ...or take identifiers, or a count.
let ids = try database.match(Person.self).where(Person.age >= 21).fetchIDs()
let total = try database.match(Person.self).count()
