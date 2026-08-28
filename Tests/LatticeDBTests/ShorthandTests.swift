import Foundation
import Testing

@testable import LatticeDB

extension PropertyKeys where Owner == Person {
  var name: PropertyKey<Person, String> { Person.name }
  var age: PropertyKey<Person, Int> { Person.age }
}

private enum Tier: String, ValueRepresentable {
  case gold
  case silver
}

@Test func keyPathShorthandMatchesTheExplicitSpelling() {
  let shorthand = Query(Person.self)
    .where(\.age, .greaterThanOrEqual, 21)
    .select(\.name)
    .orderBy(\.age, .descending)
  let explicit = Query(Person.self)
    .where(Person.age >= 21)
    .select(Person.name)
    .orderBy(Person.age, .descending)

  #expect(shorthand.cypher.text == explicit.cypher.text)
  #expect(shorthand.cypher.parameters == explicit.cypher.parameters)
}

@Test func nodeHandlesAcceptKeyPaths() throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let database = try Database(path: path)

  let ada = try database.write { try $0.createNode(.person) }
  try database.write { transaction in
    let handle = transaction.node(ada, as: Person.self)
    try handle.set(\.name, "Ada Chen")
    try handle.set(\.age, 37)
  }

  try database.read { transaction in
    let handle = transaction.node(ada, as: Person.self)
    let name = try handle[\.name]
    let age = try handle[\.age]
    #expect(name == "Ada Chen")
    #expect(age == 37)
  }
}

@Test func schemaRulesComeFromKeyTypes() throws {
  let schema = GraphSchema(
    nodes: [
      NodeSchema(.person, allowsAdditionalProperties: false) {
        Required(Person.name)
        Rule(Person.age)
        Rule("tier", .string)
      }
    ],
    edges: [
      EdgeSchema(.knows) {
        Rule("since", .integer)
      }
    ]
  )

  try schema.validateNode(
    label: "Person", properties: ["name": .string("Ada"), "age": .integer(37)])
  #expect(throws: SchemaValidationError.self) {
    try schema.validateNode(label: "Person", properties: ["age": .integer(37)])
  }
  #expect(throws: SchemaValidationError.self) {
    try schema.validateNode(label: "Person", properties: ["name": .integer(1)])
  }
  #expect(throws: SchemaValidationError.self) {
    try schema.validateNode(
      label: "Person", properties: ["name": .string("Ada"), "x": .bool(true)])
  }
  try schema.validateEdge(type: "KNOWS", properties: ["since": .integer(2019)])
}

@Test func rawRepresentableValuesRoundTrip() {
  #expect(Tier.valueKind == .string)
  #expect(Tier.gold.latticeValue == .string("gold"))
  #expect(Tier(latticeValue: .string("silver")) == .silver)
  #expect(Tier(latticeValue: .string("bronze")) == nil)

  let key = PropertyKey<Person, Tier>("tier")
  #expect((key .= .gold).value == .string("gold"))
  #expect(Rule(key).rule.kind == .string)
}
