import Foundation
import Testing

@testable import LatticeDB

enum Place: GraphNode {
  static let nodeType: NodeType = .place

  static let name = PropertyKey<Place, String>("name")
}

private func seededDatabase() throws -> (Database, String) {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  let database = try Database(path: path)
  try database.apply {
    let ada = Node(.person) {
      Person.name .= "Ada Chen"
      Person.age .= 37
    }
    let bo = Node(.person) {
      Person.name .= "Bo Lin"
      Person.age .= 24
    }
    let cafe = Node(.place) { Place.name .= "River Cafe" }
    Edge(.knows, from: ada, to: bo)
    Edge(.frequents, from: bo, to: cafe)
  }
  return (database, path)
}

// MARK: - Rendering, without a database

@Test func predicatesRenderWithBoundParameters() {
  let predicate = Person.age >= 21 && Person.name.hasPrefix("A")
  let rendered = predicate.render(variable: "p")

  #expect(rendered.text == "(p.age >= $p0 AND p.name STARTS WITH $p1)")
  #expect(rendered.parameters == ["p0": .integer(21), "p1": .string("A")])
}

@Test func predicateCombinatorsRenderAsWritten() {
  let rendered = (!(Person.age < 18) || Person.name.isNull).render(variable: "p")
  #expect(rendered.text == "(NOT (p.age < $p0) OR p.name IS NULL)")
  #expect(rendered.parameters == ["p0": .integer(18)])

  let list = Person.age.in([24, 37]).render(variable: "p")
  #expect(list.text == "p.age IN [$p0, $p1]")
  #expect(list.parameters == ["p0": .integer(24), "p1": .integer(37)])
}

@Test func queriesRenderPatternsAndClauses() {
  let query = Query(Person.self)
    .where(Person.age >= 21)
    .and(Person.name.hasPrefix("A"))
    .select(Person.name)
    .orderBy(Person.name, .descending)
    .skip(2)
    .limit(10)

  #expect(
    query.cypher.text == """
      MATCH (v0:Person) WHERE (v0.age >= $p0) AND (v0.name STARTS WITH $p1) \
      RETURN v0.name AS name ORDER BY v0.name DESC SKIP 2 LIMIT 10
      """)
  #expect(query.cypher.parameters == ["p0": .integer(21), "p1": .string("A")])
}

@Test func traversalsMoveTheCurrentEntityAndVariable() {
  let query = Query(Person.self)
    .where(Person.name == "Ada Chen")
    .outgoing(.knows, to: Person.self, as: "friend")
    .where(Person.age < 30)
    .select(Person.name, as: "friendName")

  #expect(
    query.cypher.text == """
      MATCH (v0:Person)-[:KNOWS]->(friend:Person) WHERE (v0.name = $p0) AND (friend.age < $p1) \
      RETURN friend.name AS friendName
      """)
  #expect(query.variable == "friend")
}

@Test func incomingTraversalsReverseTheArrow() {
  let query = Query(Place.self).incoming(.frequents, from: Person.self)
  #expect(query.cypher.text == "MATCH (v0:Place)<-[:FREQUENTS]-(v1:Person) RETURN v1")
}

@Test func distinctAndCountRender() {
  let query = Query(Person.self).distinct().select(Person.age).limit(5)
  #expect(query.cypher.text == "MATCH (v0:Person) RETURN DISTINCT v0.age AS age LIMIT 5")
  #expect(query.countCypher.text == "MATCH (v0:Person) RETURN count(v0) AS total")
}

@Test func validAtRendersATemporalWindow() throws {
  let date = Date(timeIntervalSince1970: 1_000)
  let query = try Query(Person.self).validAt(date).select(Person.name)

  #expect(
    query.cypher.text == """
      MATCH (v0:Person) WHERE ((v0.validFrom <= $p0 AND (v0.validTo IS NULL OR v0.validTo > $p1))) \
      RETURN v0.name AS name
      """)
  #expect(query.cypher.parameters == ["p0": .integer(1_000_000), "p1": .integer(1_000_000)])
}

@Test func hostileValuesStayParameters() {
  let query = Query(Person.self).where(Person.name == "\") RETURN 1 //")
  #expect(query.cypher.text == "MATCH (v0:Person) WHERE (v0.name = $p0) RETURN v0")
  #expect(query.cypher.parameters["p0"] == .string("\") RETURN 1 //"))
}

@Test func detachedQueriesRefuseToRun() {
  #expect(throws: QueryError.detachedQuery) { try Query(Person.self).fetchRows() }
}

// MARK: - Running

@Test func queriesRunAgainstTheGraph() throws {
  let (database, path) = try seededDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  struct Summary: Decodable, Equatable {
    let name: String
    let age: Int
  }

  let adults = try database.match(Person.self)
    .where(Person.age >= 30)
    .select(Person.name)
    .select(Person.age)
    .fetch(as: Summary.self)
  #expect(adults == [Summary(name: "Ada Chen", age: 37)])

  let ordered = try database.match(Person.self)
    .select(Person.name)
    .orderBy(Person.age, .ascending)
    .fetchRows()
  #expect(try ordered.map { try $0.value("name", as: String.self) } == ["Bo Lin", "Ada Chen"])

  let total = try database.match(Person.self).count()
  #expect(total == 2)

  let ids = try database.match(Person.self).where(Person.name == "Ada Chen").fetchIDs()
  #expect(ids.count == 1)

  let first = try database.match(Person.self).orderBy(Person.age).select(Person.name).first()
  #expect(try #require(first).value("name", as: String.self) == "Bo Lin")
}

@Test func traversalQueriesRunAcrossTwoHops() throws {
  let (database, path) = try seededDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let places = try database.match(Person.self)
    .where(Person.name == "Ada Chen")
    .outgoing(.knows, to: Person.self, as: "friend")
    .outgoing(.frequents, to: Place.self, as: "place")
    .select(Place.name)
    .fetchRows()

  #expect(try places.map { try $0.value("name", as: String.self) } == ["River Cafe"])

  let friendIDs = try database.match(Person.self)
    .where(Person.name == "Ada Chen")
    .outgoing(.knows, to: Person.self)
    .fetchIDs()
  #expect(friendIDs.count == 1)

  let friendName = try database.read { try $0.property(Person.name, ofNode: friendIDs[0]) }
  #expect(friendName == "Bo Lin")
}

@Test func validAtFiltersStoredValidityIntervals() throws {
  let (database, path) = try seededDatabase()
  defer { try? FileManager.default.removeItem(atPath: path) }

  let start = Date(timeIntervalSince1970: 1_000)
  let end = Date(timeIntervalSince1970: 2_000)
  let ids = try database.read { try $0.nodeIDs(.person) }
  try database.write { transaction in
    try transaction.setTemporalValidity(
      TemporalValidity(validFrom: start, validTo: end), onNode: ids[0])
    try transaction.setTemporalValidity(
      TemporalValidity(validFrom: end), onNode: ids[1])
  }

  let duringFirst = try database.match(Person.self)
    .validAt(Date(timeIntervalSince1970: 1_500))
    .select(Person.name)
    .fetchRows()
  #expect(duringFirst.count == 1)

  let afterBoth = try database.match(Person.self)
    .validAt(Date(timeIntervalSince1970: 2_500))
    .select(Person.name)
    .fetchRows()
  #expect(afterBoth.count == 1)
  let early = try duringFirst[0].value("name", as: String.self)
  let late = try afterBoth[0].value("name", as: String.self)
  #expect(early != late)
}

@Test(arguments: 1...8) func fragmentParameterNamesAreStable(_ iteration: Int) {
  // Fragments are merged in interpolation order, not dictionary order, so the
  // rendered text is identical from one process to the next.
  let date = Date(timeIntervalSince1970: 1_000)
  let query = try? Query(Person.self).validAt(date).where(Person.age >= 21).select(Person.name)

  #expect(
    query?.cypher.text == """
      MATCH (v0:Person) WHERE ((v0.validFrom <= $p0 AND (v0.validTo IS NULL OR v0.validTo > $p1))) \
      AND (v0.age >= $p2) RETURN v0.name AS name
      """)
  #expect(
    query?.cypher.parameters == [
      "p0": .integer(1_000_000), "p1": .integer(1_000_000), "p2": .integer(21),
    ])
}
