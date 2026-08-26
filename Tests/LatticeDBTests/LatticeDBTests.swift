import Foundation
import Testing

@testable import LatticeDB

@Test func defaultConfigurationCreatesWritableDatabase() {
  let configuration = DatabaseConfiguration()
  #expect(configuration.createIfMissing)
  #expect(!configuration.readOnly)
}

@Test func graphWorkflowPersistsAndQueries() throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }

  let database = try Database(path: path)
  let ids = try database.write { transaction in
    let ada = try transaction.createNode(label: "Person")
    try transaction.setProperty("name", onNode: ada, to: .string("Ada"))
    let cafe = try transaction.createNode(label: "Place")
    try transaction.setProperty("name", onNode: cafe, to: .string("River Cafe"))
    _ = try transaction.createEdge(from: ada, to: cafe, type: "FREQUENTS")
    return (ada, cafe)
  }

  try database.read { transaction in
    let people = try transaction.nodeIDs(label: "Person")
    let labels = try transaction.labels(of: ids.0)
    let name = try transaction.nodePropertyJSON("name", of: ids.0)
    let edges = try transaction.edgesJSON(for: ids.0, outgoing: true)
    #expect(people == [ids.0])
    #expect(labels == ["Person"])
    #expect(name == "\"Ada\"")
    #expect(edges.contains("FREQUENTS"))
  }
  let rows = try database.matchJSON("MATCH (person:Person) RETURN person.name")
  #expect(rows == "[{\"person.name\":\"Ada\"}]")

  let parameterizedRows = try database.matchJSON(
    "MATCH (person:Person) WHERE person.name = $name RETURN person.name",
    parameters: ["name": .string("Ada")]
  )
  #expect(parameterizedRows == "[{\"person.name\":\"Ada\"}]")
}

@Test func graphMetadataIndexesAndDeletionLifecycle() throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }

  let database = try Database(path: path)
  let ids = try database.write { transaction in
    let person = try transaction.createNode(label: "Person")
    let event = try transaction.createNode(label: "Event")
    _ = try transaction.createEdge(from: person, to: event, type: "ATTENDS")
    return (person, event)
  }

  try database.createNodeIndex(label: "Person", property: "name")
  try database.createEdgeIndex(type: "ATTENDS", property: "rsvp")

  let types = try database.nodeTypes()
  #expect(types == ["Event", "Person"])

  let summary = try database.nodeSummaryJSON(ids.0)
  #expect(summary.contains("\"Person\""))
  #expect(summary.contains("\"ATTENDS\""))

  try database.write { transaction in
    try transaction.deleteEdge(from: ids.0, to: ids.1, type: "ATTENDS")
    #expect(try transaction.edgesJSON(for: ids.0, outgoing: true) == "[]")
    try transaction.deleteNode(ids.1)
    #expect(!(try transaction.nodeExists(ids.1)))
  }

  try database.dropEdgeIndex(type: "ATTENDS", property: "rsvp")
  try database.dropNodeIndex(label: "Person", property: "name")
}

@Test func schemaValidationAndTemporalValidityAreOptIn() throws {
  let schema = GraphSchema(
    nodes: [
      NodeSchema(
        label: "Person",
        properties: [
          "name": .init(kind: .string, required: true),
          "born": .init(kind: .integer),
        ],
        allowsAdditionalProperties: false
      )
    ],
    edges: [EdgeSchema(type: "KNOWS", properties: ["since": .init(kind: .integer, required: true)])]
  )

  #expect(throws: SchemaValidationError.missingRequiredProperty(entity: "Person", property: "name"))
  {
    try schema.validateNode(label: "Person", properties: [:])
  }
  #expect(
    throws: SchemaValidationError.invalidPropertyType(
      entity: "Person", property: "born", expected: .integer, actual: .string)
  ) {
    try schema.validateNode(
      label: "Person", properties: ["name": .string("Ada"), "born": .string("1815")])
  }

  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let database = try Database(path: path)
  let node = try database.write { transaction in
    try schema.createNode(in: transaction, label: "Person", properties: ["name": .string("Ada")])
  }
  let validity = try TemporalValidity(
    validFrom: Date(timeIntervalSince1970: 1_000),
    validTo: Date(timeIntervalSince1970: 2_000)
  )
  #expect(validity.contains(Date(timeIntervalSince1970: 1_500)))
  #expect(!validity.contains(Date(timeIntervalSince1970: 2_000)))
  try database.write { transaction in
    try transaction.setTemporalValidity(validity, onNode: node)
  }
  let validFrom = try database.read { transaction in
    try transaction.nodePropertyJSON("validFrom", of: node)
  }
  #expect(validFrom == "1000000")

  let asOf = try TemporalAsOf(date: Date(timeIntervalSince1970: 1_500))
  let predicate = try asOf.predicate(for: "person")
  let rows = try database.matchJSON(
    "MATCH (person:Person) WHERE \(predicate) RETURN person.name",
    parameters: asOf.parameters
  )
  #expect(rows == "[{\"person.name\":\"Ada\"}]")
}
