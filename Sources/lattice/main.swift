import ArgumentParser
import CommandREPL
import Foundation
import LatticeDB

private final class DatabaseSession: @unchecked Sendable {
  static let shared = DatabaseSession()
  private let lock = NSLock()
  private var database: Database?
  private var path: String?

  func open(path: String, readOnly: Bool) throws {
    let database = try Database(
      path: path, configuration: .init(createIfMissing: !readOnly, readOnly: readOnly))
    lock.lock()
    defer { lock.unlock() }
    self.database = database
    self.path = path
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    database = nil
    path = nil
  }

  func withDatabase<T>(
    path explicitPath: String?, readOnly: Bool = false, _ body: (Database) throws -> T
  ) throws -> T {
    if let explicitPath {
      let configuration = DatabaseConfiguration(createIfMissing: !readOnly, readOnly: readOnly)
      return try body(Database(path: explicitPath, configuration: configuration))
    }
    lock.lock()
    defer { lock.unlock() }
    guard let database else {
      throw ValidationError("Open a database with `database open <path>`, or pass --database.")
    }
    return try body(database)
  }

  var description: String {
    lock.lock()
    defer { lock.unlock() }
    return path ?? "No default database open."
  }
}

enum PropertyType: String, ExpressibleByArgument { case string, int, double, bool, null }
enum QueryFormat: String, ExpressibleByArgument { case json, table, csv }

private func propertyValue(_ raw: String, type: PropertyType?) throws -> Value {
  switch type {
  case .string: return .string(raw)
  case .int:
    guard let value = Int64(raw) else { throw ValidationError("\(raw) is not an integer.") }
    return .integer(value)
  case .double:
    guard let value = Double(raw) else { throw ValidationError("\(raw) is not a double.") }
    return .double(value)
  case .bool:
    guard let value = Bool(raw) else { throw ValidationError("\(raw) is not true or false.") }
    return .bool(value)
  case .null: return .null
  case nil:
    if raw == "true" { return .bool(true) }
    if raw == "false" { return .bool(false) }
    if let integer = Int64(raw), raw == "0" || !raw.hasPrefix("0") && !raw.hasPrefix("-0") {
      return .integer(integer)
    }
    if raw.contains("."), let double = Double(raw) { return .double(double) }
    return .string(raw)
  }
}

private func queryParameters(_ rawParameters: [String]) throws -> [String: Value] {
  var parameters: [String: Value] = [:]
  for raw in rawParameters {
    guard let separator = raw.firstIndex(of: "=") else {
      throw ValidationError("Parameter \(raw) must use name=value syntax.")
    }
    let name = String(raw[..<separator])
    let value = String(raw[raw.index(after: separator)...])
    guard !name.isEmpty else { throw ValidationError("Parameter names cannot be empty.") }
    guard parameters[name] == nil else {
      throw ValidationError("Parameter \(name) was provided more than once.")
    }
    parameters[name] = try propertyValue(value, type: nil)
  }
  return parameters
}

private func renderQuery(_ json: String, format: QueryFormat) throws -> String {
  guard format != .json else { return json }
  let data = Data(json.utf8)
  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
  let columns = Array(Set(rows.flatMap(\.keys))).sorted()
  let values = rows.map { row in
    columns.map { key -> String in
      guard let value = row[key], !(value is NSNull) else { return "" }
      return value as? String ?? String(describing: value)
    }
  }
  switch format {
  case .json: return json
  case .csv:
    func escape(_ value: String) -> String {
      "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return ([columns] + values).map { $0.map(escape).joined(separator: ",") }.joined(
      separator: "\n")
  case .table:
    let widths = columns.indices.map { index in
      max(columns[index].count, values.map { $0[index].count }.max() ?? 0)
    }
    func line(_ cells: [String]) -> String {
      "| "
        + zip(cells, widths).map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }
        .joined(separator: " | ") + " |"
    }
    let divider =
      "|-" + widths.map { String(repeating: "-", count: $0) }.joined(separator: "-|-") + "-|"
    return ([line(columns), divider] + values.map(line)).joined(separator: "\n")
  }
}

@main struct LatticeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lattice",
    subcommands: [
      Version.self, REPL.self, Demo.self, DatabaseCommand.self, Node.self, Edge.self, Index.self,
      Match.self,
    ])
  struct Version: ParsableCommand { mutating func run() { print(LatticeDB.nativeVersion) } }
  struct REPL: AsyncParsableCommand {
    @Option var database: String?
    @Flag var readOnly = false

    mutating func run() async throws {
      if let database { try DatabaseSession.shared.open(path: database, readOnly: readOnly) }
      try await LatticeCommand.readEvalPrintLoop()
    }
  }

  struct Demo: ParsableCommand {
    @Option var database = "Examples/people-places-events.db"
    mutating func run() throws {
      guard !FileManager.default.fileExists(atPath: database) else {
        throw ValidationError("\(database) already exists. Choose a different --database path.")
      }
      let db = try Database(path: database)
      try db.write { transaction in
        let ada = try transaction.createNode(label: "Person")
        try transaction.setProperty("name", onNode: ada, to: .string("Ada Chen"))
        try transaction.setProperty("role", onNode: ada, to: .string("Urban designer"))
        let ben = try transaction.createNode(label: "Person")
        try transaction.setProperty("name", onNode: ben, to: .string("Ben Ortiz"))
        try transaction.setProperty("role", onNode: ben, to: .string("Community gardener"))
        let chandra = try transaction.createNode(label: "Person")
        try transaction.setProperty("name", onNode: chandra, to: .string("Chandra Rao"))
        try transaction.setProperty("role", onNode: chandra, to: .string("Historian"))
        let cafe = try transaction.createNode(label: "Place")
        try transaction.setProperty("name", onNode: cafe, to: .string("River Cafe"))
        try transaction.setProperty("neighborhood", onNode: cafe, to: .string("Old Wharf"))
        let hall = try transaction.createNode(label: "Place")
        try transaction.setProperty("name", onNode: hall, to: .string("North Hall"))
        let park = try transaction.createNode(label: "Place")
        try transaction.setProperty("name", onNode: park, to: .string("Harbor Park"))
        let salon = try transaction.createNode(label: "Event")
        try transaction.setProperty("name", onNode: salon, to: .string("Design Salon"))
        try transaction.setProperty("date", onNode: salon, to: .string("2026-09-10"))
        let volunteer = try transaction.createNode(label: "Event")
        try transaction.setProperty("name", onNode: volunteer, to: .string("Volunteer Day"))
        try transaction.setProperty("date", onNode: volunteer, to: .string("2026-09-14"))
        _ = try transaction.createEdge(from: ada, to: ben, type: "KNOWS")
        _ = try transaction.createEdge(from: ben, to: chandra, type: "KNOWS")
        _ = try transaction.createEdge(from: ada, to: cafe, type: "FREQUENTS")
        _ = try transaction.createEdge(from: ben, to: park, type: "CARES_FOR")
        _ = try transaction.createEdge(from: salon, to: hall, type: "HAPPENS_AT")
        _ = try transaction.createEdge(from: volunteer, to: park, type: "HAPPENS_AT")
        _ = try transaction.createEdge(from: ada, to: salon, type: "ATTENDS")
        _ = try transaction.createEdge(from: ben, to: volunteer, type: "ATTENDS")
      }
      print("Created \(database). Start with: lattice repl, then database open \(database)")
    }
  }

  struct DatabaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "database", subcommands: [Open.self, Close.self, Status.self])
    struct Open: ParsableCommand {
      @Argument var path: String
      @Flag var readOnly = false
      mutating func run() throws {
        try DatabaseSession.shared.open(path: path, readOnly: readOnly)
        print("Default database: \(path)")
      }
    }
    struct Close: ParsableCommand { mutating func run() { DatabaseSession.shared.close() } }
    struct Status: ParsableCommand {
      mutating func run() { print(DatabaseSession.shared.description) }
    }
  }

  struct Node: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [
      Create.self, List.self, Show.self, Labels.self, Property.self, Set.self, Types.self,
      Delete.self,
    ])
    struct Create: ParsableCommand {
      @Option var database: String?
      @Option var label: String?
      mutating func run() throws {
        let id = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.write { try $0.createNode(label: label) }
        }
        print(id)
      }
    }
    struct List: ParsableCommand {
      @Option var database: String?
      @Option var label: String
      mutating func run() throws {
        let ids = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.read { try $0.nodeIDs(label: label) }
        }
        for id in ids { print(id) }
      }
    }
    struct Show: ParsableCommand {
      @Option var database: String?
      @Argument var node: UInt64
      mutating func run() throws {
        let json = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.nodeSummaryJSON(node)
        }
        print(json)
      }
    }
    struct Labels: ParsableCommand {
      @Option var database: String?
      @Argument var node: UInt64
      mutating func run() throws {
        let labels = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.read { try $0.labels(of: node) }
        }
        for label in labels { print(label) }
      }
    }
    struct Property: ParsableCommand {
      @Option var database: String?
      @Argument var node: UInt64
      @Argument var key: String
      mutating func run() throws {
        let json = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.read { try $0.nodePropertyJSON(key, of: node) }
        }
        print(json)
      }
    }
    struct Set: ParsableCommand {
      @Option var database: String?
      @Option var value: String
      @Option var type: PropertyType?
      @Argument var node: UInt64
      @Argument var key: String
      mutating func run() throws {
        let value = try propertyValue(value, type: type)
        try DatabaseSession.shared.withDatabase(path: database) {
          try $0.write { try $0.setProperty(key, onNode: node, to: value) }
        }
      }
    }
    struct Types: ParsableCommand {
      @Option var database: String?
      mutating func run() throws {
        let types = try DatabaseSession.shared.withDatabase(path: database) { try $0.nodeTypes() }
        for type in types { print(type) }
      }
    }
    struct Delete: ParsableCommand {
      @Option var database: String?
      @Argument var node: UInt64
      mutating func run() throws {
        try DatabaseSession.shared.withDatabase(path: database) {
          try $0.write { try $0.deleteNode(node) }
        }
      }
    }
  }

  struct Edge: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [
      Create.self, Outgoing.self, Incoming.self, Set.self, Delete.self,
    ])
    struct Create: ParsableCommand {
      @Option var database: String?
      @Option var source: UInt64
      @Option var target: UInt64
      @Option(name: .long) var type: String
      mutating func run() throws {
        let id = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.write { try $0.createEdge(from: source, to: target, type: type) }
        }
        print(id)
      }
    }
    struct Outgoing: ParsableCommand {
      @Option var database: String?
      @Option var type: String?
      @Argument var node: UInt64
      mutating func run() throws {
        let json = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.read { try $0.edgesJSON(for: node, outgoing: true, type: type) }
        }
        print(json)
      }
    }
    struct Incoming: ParsableCommand {
      @Option var database: String?
      @Option var type: String?
      @Argument var node: UInt64
      mutating func run() throws {
        let json = try DatabaseSession.shared.withDatabase(path: database) {
          try $0.read { try $0.edgesJSON(for: node, outgoing: false, type: type) }
        }
        print(json)
      }
    }
    struct Set: ParsableCommand {
      @Option var database: String?
      @Option var value: String
      @Option var type: PropertyType?
      @Argument var edge: UInt64
      @Argument var key: String
      mutating func run() throws {
        let value = try propertyValue(value, type: type)
        try DatabaseSession.shared.withDatabase(path: database) {
          try $0.write { try $0.setProperty(key, onEdge: edge, to: value) }
        }
      }
    }
    struct Delete: ParsableCommand {
      @Option var database: String?
      @Option var source: UInt64
      @Option var target: UInt64
      @Option(name: .long) var type: String
      mutating func run() throws {
        try DatabaseSession.shared.withDatabase(path: database) {
          try $0.write { try $0.deleteEdge(from: source, to: target, type: type) }
        }
      }
    }
  }
  struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Node.self, Edge.self])
    struct Node: ParsableCommand {
      static let configuration = CommandConfiguration(subcommands: [Create.self, Drop.self])
      struct Create: ParsableCommand {
        @Option var database: String?
        @Option var label: String
        @Option var property: String
        mutating func run() throws {
          try DatabaseSession.shared.withDatabase(path: database) {
            try $0.createNodeIndex(label: label, property: property)
          }
        }
      }
      struct Drop: ParsableCommand {
        @Option var database: String?
        @Option var label: String
        @Option var property: String
        mutating func run() throws {
          try DatabaseSession.shared.withDatabase(path: database) {
            try $0.dropNodeIndex(label: label, property: property)
          }
        }
      }
    }
    struct Edge: ParsableCommand {
      static let configuration = CommandConfiguration(subcommands: [Create.self, Drop.self])
      struct Create: ParsableCommand {
        @Option var database: String?
        @Option var type: String
        @Option var property: String
        mutating func run() throws {
          try DatabaseSession.shared.withDatabase(path: database) {
            try $0.createEdgeIndex(type: type, property: property)
          }
        }
      }
      struct Drop: ParsableCommand {
        @Option var database: String?
        @Option var type: String
        @Option var property: String
        mutating func run() throws {
          try DatabaseSession.shared.withDatabase(path: database) {
            try $0.dropEdgeIndex(type: type, property: property)
          }
        }
      }
    }
  }
  struct Match: ParsableCommand {
    @Option var database: String?
    @Option var format: QueryFormat = .json
    @Option var file: String?
    @Option(name: .long) var param: [String] = []
    @Argument var cypher: String?

    mutating func run() throws {
      let query: String
      switch (cypher, file) {
      case (.some(let cypher), nil): query = cypher
      case (nil, .some(let file)): query = try String(contentsOfFile: file, encoding: .utf8)
      case (.none, .none): throw ValidationError("Provide Cypher text or --file <path>.")
      case (.some, .some): throw ValidationError("Use either Cypher text or --file, not both.")
      }
      let parameters = try queryParameters(param)
      let json = try DatabaseSession.shared.withDatabase(path: database, readOnly: true) {
        try $0.matchJSON(query, parameters: parameters)
      }
      print(try renderQuery(json, format: format))
    }
  }
}
