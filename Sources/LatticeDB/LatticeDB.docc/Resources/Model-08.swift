// A misspelled key is now an error instead of a stray property.
do {
  _ = try database.write { transaction in
    try schema.createNode(
      in: transaction,
      label: "Person",
      properties: ["nmae": .string("Dara Okoro")]
    )
  }
} catch SchemaValidationError.unexpectedProperty(let entity, let property) {
  print("\(entity) has no property named \(property)")
  // Person has no property named nmae
}

// So is a missing required property, or one of the wrong kind.
do {
  _ = try database.write { transaction in
    try schema.createNode(
      in: transaction,
      label: "Person",
      properties: ["name": .integer(7)]
    )
  }
} catch SchemaValidationError.invalidPropertyType(_, let property, let expected, let actual) {
  print("\(property): expected \(expected), got \(actual)")
  // name: expected string, got integer
}
