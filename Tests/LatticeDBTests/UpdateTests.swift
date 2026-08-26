import Foundation
import Testing

@testable import LatticeDB

extension Person {
  static let email = PropertyKey<Person, String>("email")
}

private func newDatabase() throws -> (Database, String) {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  return (try Database(path: path), path)
}

@Test func upsertReusesTheIndexedNode() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }
  try database.createNodeIndex(label: "Person", property: "email")

  try database.update {
    Upsert(.person, matching: Person.email, "ada@example.com") {
      Person.name .= "Ada"
      Person.age .= 36
    }
  }
  try database.update {
    Upsert(.person, matching: Person.email, "ada@example.com") {
      Person.age .= 37
    }
  }

  let people = try database.read { try $0.nodeIDs(.person) }
  #expect(people.count == 1)
  try database.read { transaction in
    let name = try transaction.property(Person.name, ofNode: people[0])
    let age = try transaction.property(Person.age, ofNode: people[0])
    let email = try transaction.propertyValue("email", ofNode: people[0])
    #expect(name == "Ada")
    #expect(age == 37)
    #expect(email == .string("ada@example.com"))
  }
}

@Test func upsertWithoutAnIndexFailsUnlessScanningIsRequested() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  #expect(throws: GraphPlanError.indexRequired(label: "Person", property: "email")) {
    try database.update {
      Upsert(.person, matching: "email", equals: .string("bo@example.com")) {
        Person.name .= "Bo"
      }
    }
  }
  let untouched = try database.read { try $0.allNodeIDs() }
  #expect(untouched.isEmpty)

  try database.update(mergeStrategy: .scanIfUnindexed) {
    Upsert(.person, matching: "email", equals: .string("bo@example.com")) {
      Person.name .= "Bo"
    }
  }
  try database.update(mergeStrategy: .scanIfUnindexed) {
    Upsert(.person, matching: "email", equals: .string("bo@example.com")) {
      Person.name .= "Bo Lin"
    }
  }

  let people = try database.read { try $0.nodeIDs(.person) }
  #expect(people.count == 1)
  let name = try database.read { try $0.property(Person.name, ofNode: people[0]) }
  #expect(name == "Bo Lin")
}

@Test func connectCreatesEachEdgeOnce() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let ids = try database.write { transaction in
    (try transaction.createNode(.person), try transaction.createNode(.person))
  }

  for year in [2019, 2020] {
    try database.update {
      Connect(.knows, from: ids.0, to: ids.1) { Property("since", .integer(Int64(year))) }
    }
  }

  try database.read { transaction in
    let edges = try transaction.edges(for: ids.0, outgoing: true, type: .knows)
    #expect(edges.count == 1)
    let since = try transaction.propertyValue("since", ofEdge: edges[0].id)
    #expect(since == .integer(2020))
  }
}

@Test func mutationVerbsChangeExistingGraphState() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let ids = try database.write { transaction in
    let ada = try transaction.createNode(.person)
    let bo = try transaction.createNode(.person)
    let stale = try transaction.createNode(.place)
    _ = try transaction.createEdge(from: ada, to: bo, type: .knows)
    return (ada, bo, stale)
  }

  try database.update {
    AddLabel(.customer, to: ids.0)
    Update(node: ids.0) { Person.name .= "Ada Chen" }
    Disconnect(.knows, from: ids.0, to: ids.1)
    Delete(node: ids.2)
  }

  try database.read { transaction in
    let labels = try transaction.nodeTypes(of: ids.0).sorted { $0.rawValue < $1.rawValue }
    let name = try transaction.property(Person.name, ofNode: ids.0)
    let edges = try transaction.edges(for: ids.0, outgoing: true)
    let staleExists = try transaction.nodeExists(ids.2)
    #expect(labels == [.customer, .person])
    #expect(name == "Ada Chen")
    #expect(edges.isEmpty)
    #expect(!staleExists)
  }

  try database.update { RemoveLabel(.customer, from: ids.0) }
  let labels = try database.read { try $0.nodeTypes(of: ids.0) }
  #expect(labels == [.person])
}

@Test func nodeHandleReadsAndWritesInPlace() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let ada = try database.write { transaction in
    let ada = try transaction.createNode(.person)
    try transaction.setProperty(Person.age, onNode: ada, to: 36)
    return ada
  }

  try database.write { transaction in
    let handle = transaction.node(ada, as: Person.self)
    let age = try handle[Person.age] ?? 0
    try handle.set(Person.age, age + 1)
    try handle.set {
      Person.name .= "Ada Chen"
    }
    try handle.addLabel(.customer)
  }

  try database.read { transaction in
    let handle = transaction.node(ada, as: Person.self)
    let age = try handle[Person.age]
    let name = try handle[Person.name]
    let labels = try handle.labels.sorted { $0.rawValue < $1.rawValue }
    let exists = try handle.exists
    #expect(age == 37)
    #expect(name == "Ada Chen")
    #expect(labels == [.customer, .person])
    #expect(exists)
  }
}

@Test func transactionQueriesSeeUncommittedWrites() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  try database.write { transaction in
    let ada = try transaction.createNode(.person)
    try transaction.setProperty(Person.name, onNode: ada, to: "Ada Chen")

    let inside = try transaction.match("MATCH (p:Person) RETURN p.name AS name")
    #expect(inside.count == 1)

    // The database-level query opens its own read-only transaction and so does
    // not observe the write above.
    let outside = try database.match("MATCH (p:Person) RETURN p.name AS name")
    #expect(outside.isEmpty)
  }

  let afterCommit = try database.match("MATCH (p:Person) RETURN p.name AS name")
  #expect(afterCommit.count == 1)
}

@Test func edgePropertiesReadAndRemoveByEdgeIdentifier() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let result = try database.apply {
    let ada = Node(.person) { Person.name .= "Ada" }
    let bo = Node(.person) { Person.name .= "Bo" }
    Edge(.knows, from: ada, to: bo) { Property("since", .integer(2019)) }
  }
  let edge = try #require(result.edges.first)

  try database.read { transaction in
    let since = try transaction.propertyValue("since", ofEdge: edge)
    #expect(since == .integer(2019))
  }

  try database.write { try $0.removeProperty("since", fromEdge: edge) }

  try database.read { transaction in
    let since = try transaction.propertyValue("since", ofEdge: edge)
    #expect(since == .null)
  }
}

@Test func indexedLookupFindsNodesByProperty() throws {
  let (database, path) = try newDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }
  try database.createNodeIndex(label: "Person", property: "name")

  try database.apply {
    Node(.person) { Person.name .= "Ada Chen" }
    Node(.person) { Person.name .= "Bo Lin" }
  }

  let found = try database.read {
    try $0.nodeIDs(.person, where: Person.name, equals: "Bo Lin")
  }
  #expect(found.count == 1)
  let name = try database.read { try $0.property(Person.name, ofNode: found[0]) }
  #expect(name == "Bo Lin")
}
