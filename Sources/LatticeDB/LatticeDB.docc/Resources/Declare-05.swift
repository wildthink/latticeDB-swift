// Rules take their kind from the key's Swift type.
let schema = GraphSchema(
  nodes: [
    NodeSchema(.person, allowsAdditionalProperties: false) {
      Required(Person.name)
      Rule(Person.age)
    }
  ]
)

// A misspelled key is an error, and nothing is written.
do {
  try database.apply(schema: schema) {
    Node(.person) { Property("nmae", .string("Dara Okoro")) }
  }
} catch SchemaValidationError.unexpectedProperty(let entity, let property) {
  print("\(entity) has no property named \(property)")
  // Person has no property named nmae
}
