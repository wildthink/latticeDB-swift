import Foundation
import Testing

@testable import LatticeDB

extension NodeType {
  static let person: NodeType = "Person"
  static let place: NodeType = "Place"
  static let customer: NodeType = "Customer"
}

extension EdgeType {
  static let knows: EdgeType = "KNOWS"
  static let frequents: EdgeType = "FREQUENTS"
}

enum Person: GraphNode {
  static let nodeType: NodeType = .person

  static let name = PropertyKey<Person, String>("name")
  static let age = PropertyKey<Person, Int>("age")
  static let joined = PropertyKey<Person, Date>("joined")
}

private func temporaryDatabase() throws -> (Database, String) {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  return (try Database(path: path), path)
}

// MARK: - Keys

@Test func typedKeysRoundTripThroughScalars() {
  #expect((Person.name .= "Ada").value == .string("Ada"))
  #expect((Person.age .= 37).value == .integer(37))
  #expect(Int(latticeValue: .integer(37)) == 37)
  #expect(Int(latticeValue: .string("37")) == nil)
  #expect(Double(latticeValue: .integer(2)) == 2)
  #expect(String?(latticeValue: .null) == .some(nil))

  let date = Date(timeIntervalSince1970: 1.5)
  #expect(date.latticeValue == .integer(1_500))
  #expect(Date(latticeValue: .integer(1_500)) == date)
}

@Test func assignmentsCollapseToPropertyValuesInOrder() {
  let assignments = [Person.name .= "Ada", Person.age .= 1, Person.name .= "Ada Chen"]
  #expect(assignments.propertyValues == ["name": .string("Ada Chen"), "age": .integer(1)])
}

// MARK: - Builder

@Test func planCapturesDeclarationsWithoutADatabase() {
  let plan = GraphPlan {
    let ada = Node(.person, .customer) {
      Person.name .= "Ada Chen"
      Person.age .= 37
    }
    let cafe = Node(.place) { Property("name", .string("River Cafe")) }
    Edge(.frequents, from: ada, to: cafe) { Property("since", .integer(2019)) }
  }

  #expect(plan.elements.count == 1)
  #expect(plan.edgeSpecs.count == 1)

  let edge = plan.edgeSpecs[0]
  #expect(edge.type == .frequents)
  guard case .spec(let source) = edge.source, case .spec(let target) = edge.target else {
    Issue.record("endpoints should be declared nodes")
    return
  }
  #expect(source.labels == [.person, .customer])
  #expect(source.properties.propertyValues["name"] == .string("Ada Chen"))
  #expect(target.labels == [.place])
}

@Test func builderSupportsControlFlowAndComposition() {
  let includeCustomer = true
  let plan = GraphPlan {
    Node(Person.self) { Person.name .= "Ada" }
    if includeCustomer {
      Node(.customer) { Property("tier", .string("gold")) }
    }
    for index in 0..<3 {
      Node(.person) { Person.age .= index }
    }
  }

  #expect(plan.nodeSpecs.count == 5)
  #expect(plan.nodeSpecs[0].labels == [.person])
  #expect(plan.nodeSpecs[1].labels == [.customer])
  #expect(plan.nodeSpecs[4].properties.propertyValues["age"] == .integer(2))
}

@Test func planValidatesAgainstSchemaBeforeWriting() throws {
  let schema = GraphSchema(
    nodes: [
      NodeSchema(
        label: "Person",
        properties: ["name": PropertyRule(kind: .string, required: true)],
        allowsAdditionalProperties: false
      )
    ]
  )
  let plan = GraphPlan {
    Node(.person) { Property("nmae", .string("Ada")) }
  }

  #expect(throws: SchemaValidationError.self) { try plan.validate(with: schema) }

  let (database, path) = try temporaryDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }
  #expect(throws: SchemaValidationError.self) {
    try database.apply(schema: schema) { plan }
  }
  let remaining = try database.read { try $0.allNodeIDs() }
  #expect(remaining.isEmpty)
}

@Test func applyingAPlanCreatesNodesEdgesAndResolvesReferences() throws {
  let (database, path) = try temporaryDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let ada = Node(.person, .customer) {
    Person.name .= "Ada Chen"
    Person.age .= 37
  }
  let cafe = Node(.place) { Property("name", .string("River Cafe")) }
  let result = try database.apply {
    ada
    Edge(.frequents, from: ada, to: cafe) { Property("since", .integer(2019)) }
  }

  let adaID = try #require(result[ada])
  let cafeID = try #require(result[cafe])
  #expect(result.edges.count == 1)

  try database.read { transaction in
    let labels = try transaction.nodeTypes(of: adaID).sorted { $0.rawValue < $1.rawValue }
    let name = try transaction.property(Person.name, ofNode: adaID)
    let age = try transaction.property(Person.age, ofNode: adaID)
    let neighbors = try transaction.neighbors(of: adaID, type: .frequents)
    let incoming = try transaction.edges(for: cafeID, outgoing: false).map(\.type)
    #expect(labels == [.customer, .person])
    #expect(name == "Ada Chen")
    #expect(age == 37)
    #expect(neighbors == [cafeID])
    #expect(incoming == [.frequents])
  }
}

@Test func applyingResolvesExistingNodesAndReportsMissingOnes() throws {
  let (database, path) = try temporaryDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let seeded = try database.write { try $0.createNode(.person) }
  let updated = Node(existing: seeded, adding: .customer) { Person.name .= "Ada" }
  try database.apply { updated }

  try database.read { transaction in
    let name = try transaction.property(Person.name, ofNode: seeded)
    let labels = try transaction.nodeTypes(of: seeded)
    #expect(name == "Ada")
    #expect(labels.contains(.customer))
  }

  #expect(throws: GraphPlanError.missingNode(9_999)) {
    try database.apply { Node(existing: 9_999) { Person.name .= "Nobody" } }
  }
}

@Test func unsetPropertiesReadAsNil() throws {
  let (database, path) = try temporaryDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let id = try database.write { try $0.createNode(.person) }
  try database.read { transaction in
    let name = try transaction.property(Person.name, ofNode: id)
    let raw = try transaction.propertyValue("name", ofNode: id)
    #expect(name == nil)
    #expect(raw == .null)
  }
}

// MARK: - Cypher

@Test func interpolationBindsValuesAndSplicesIdentifiers() {
  let name = "Ada Chen"
  let query: Cypher =
    "MATCH (p:\(NodeType.person)) WHERE p.\(Person.name) = \(name) RETURN p.name AS name"

  #expect(query.text == "MATCH (p:Person) WHERE p.name = $p0 RETURN p.name AS name")
  #expect(query.parameters == ["p0": .string("Ada Chen")])
}

@Test func interpolationBindsInjectionAttemptsAsParameters() throws {
  let hostile = "\") RETURN 1 //"
  let query: Cypher = "MATCH (p:Person) WHERE p.name = \(hostile) RETURN p"

  #expect(query.text == "MATCH (p:Person) WHERE p.name = $p0 RETURN p")
  #expect(query.parameters == ["p0": .string(hostile)])
  #expect(try query.validated().text == query.text)
}

@Test func invalidIdentifiersSurfaceWhenTheQueryIsValidated() {
  let query: Cypher = "MATCH (p:\(NodeType("Person) RETURN 1 //"))) RETURN p"
  #expect(throws: CypherError.invalidIdentifier("Person) RETURN 1 //")) {
    try query.validated()
  }
}

@Test func nestedFragmentsRenumberTheirParameters() {
  let predicate: Cypher = "p.age > \(21)"
  let query: Cypher =
    "MATCH (p:Person) WHERE \(predicate) AND p.name = \("Ada") RETURN p"

  #expect(query.text == "MATCH (p:Person) WHERE p.age > $p0 AND p.name = $p1 RETURN p")
  #expect(query.parameters == ["p0": .integer(21), "p1": .string("Ada")])
}

@Test func rawInterpolationSplicesTextUnchanged() {
  let query: Cypher = "MATCH (p:Person) RETURN p \(raw: "LIMIT 10")"
  #expect(query.text == "MATCH (p:Person) RETURN p LIMIT 10")
  #expect(query.parameters.isEmpty)
}

// MARK: - Rows

@Test func rowsParseScalarsAndNodes() throws {
  let rows = try parseRows(
    """
    [{"name":"Ada","age":37,"score":1.5,"active":true,"missing":null,
      "p":{"id":7,"labels":["Person"],"name":"Ada"}}]
    """
  )
  let row = try #require(rows.first)

  #expect(try row.value("name", as: String.self) == "Ada")
  #expect(try row.value(Person.age) == 37)
  #expect(try row.value("score", as: Double.self) == 1.5)
  #expect(try row.value("active", as: Bool.self) == true)
  #expect(row["missing"] == .null)
  #expect(throws: QueryError.missingColumn("absent")) { try row.value("absent", as: Int.self) }
  #expect(throws: QueryError.valueTypeMismatch(column: "name", expected: "Int")) {
    try row.value("name", as: Int.self)
  }

  let node = try row.node("p")
  #expect(node.id == 7)
  #expect(node.labels == [.person])
  #expect(node.value(Person.name) == "Ada")
}

@Test func matchDecodesRowsAndScalars() throws {
  let (database, path) = try temporaryDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  try database.apply {
    Node(.person) {
      Person.name .= "Ada Chen"
      Person.age .= 37
    }
    Node(.person) {
      Person.name .= "Bo Lin"
      Person.age .= 24
    }
  }

  struct Summary: Decodable, Equatable {
    let name: String
    let age: Int
  }

  let people = try database.match(
    "MATCH (p:\(NodeType.person)) WHERE p.age > \(30) RETURN p.name AS name, p.age AS age",
    as: Summary.self
  )
  #expect(people == [Summary(name: "Ada Chen", age: 37)])

  let rows = try database.match("MATCH (p:Person) RETURN p.name AS name")
  #expect(
    try rows.map { try $0.value("name", as: String.self) }.sorted() == ["Ada Chen", "Bo Lin"])

  let total = try database.matchCount("MATCH (p:Person) RETURN count(p) AS total")
  #expect(total == 2)

  let first = try database.matchFirst(
    "MATCH (p:Person) WHERE p.name = \("Bo Lin") RETURN p.age AS age")
  #expect(try #require(first).value("age", as: Int.self) == 24)
}

@Test func plansAreSendableAcrossConcurrencyDomains() async throws {
  let plan = GraphPlan {
    Node(.person) { Person.name .= "Ada" }
  }
  let elements = await Task.detached { plan.elements.count }.value
  #expect(elements == 1)
}
