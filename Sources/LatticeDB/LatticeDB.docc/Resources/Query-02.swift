let json = try database.matchJSON(
  """
  MATCH (person:Person)
  WHERE person.name = $name
  RETURN person.name, person.role
  """,
  parameters: ["name": .string("Ada Chen")]
)
print(json)
// [{"person.name":"Ada Chen","person.role":"Urban designer"}]
