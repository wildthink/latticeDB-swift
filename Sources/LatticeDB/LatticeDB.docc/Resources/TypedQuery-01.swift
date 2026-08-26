// A typed query is a pattern over modeled entities. Nothing runs until you fetch.
let adults = try database.match(Person.self)
  .where(Person.age >= 21)
  .select(Person.name)
  .select(Person.age)
  .orderBy(Person.age, .descending)
  .limit(10)
  .fetchRows()
