let json = try database.matchJSON("MATCH (person:Person) RETURN person.name")
print(json)
// [{"person.name":"Ada Chen"},{"person.name":"Ben Ortiz"},{"person.name":"Chandra Rao"}]
