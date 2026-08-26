import Foundation
import LatticeBridge

extension Database {
  /// Runs a read-only native query and returns its rows.
  ///
  /// ```swift
  /// let rows = try database.match(
  ///   "MATCH (p:\(NodeType.person)) WHERE p.age > \(30) RETURN p.name AS name"
  /// )
  /// let names = try rows.map { try $0.value("name", as: String.self) }
  /// ```
  ///
  /// The query runs in its own read-only transaction, so it does not observe
  /// uncommitted writes of an enclosing ``Database/write(_:)`` block. Queries
  /// that write are rejected by the native bridge.
  public func match(_ cypher: Cypher) throws -> [Row] {
    try parseRows(matchJSON(cypher.validated().text, parameters: cypher.parameters))
  }

  /// Runs a read-only native query and decodes each row.
  ///
  /// Column names become the decoded type's coding keys, so name the returned
  /// expressions with `AS`.
  ///
  /// ```swift
  /// struct Person: Decodable { let name: String; let age: Int }
  /// let people = try database.match(
  ///   "MATCH (p:Person) RETURN p.name AS name, p.age AS age", as: Person.self)
  /// ```
  public func match<T: Decodable>(_ cypher: Cypher, as type: T.Type) throws -> [T] {
    let json = try matchJSON(cypher.validated().text, parameters: cypher.parameters)
    do {
      return try JSONDecoder().decode([T].self, from: Data(json.utf8))
    } catch {
      throw QueryError.malformedResult("\(error)")
    }
  }

  /// Runs a query and returns its first row, or `nil` when it matched nothing.
  public func matchFirst(_ cypher: Cypher) throws -> Row? {
    try match(cypher).first
  }

  /// Runs a query and returns its first row decoded, or `nil` when it matched
  /// nothing.
  public func matchFirst<T: Decodable>(_ cypher: Cypher, as type: T.Type) throws -> T? {
    try match(cypher, as: type).first
  }

  /// Runs a single-column query and returns the first value.
  ///
  /// ```swift
  /// let total = try database.matchScalar(
  ///   "MATCH (p:Person) RETURN count(p) AS total", as: Int.self)
  /// ```
  ///
  /// - Throws: ``QueryError/malformedResult(_:)`` when the query returns more
  ///   than one column.
  public func matchScalar<V: ValueRepresentable>(
    _ cypher: Cypher, as type: V.Type = V.self
  ) throws -> V? {
    guard let row = try matchFirst(cypher) else { return nil }
    guard row.columns.count == 1, let column = row.columnNames.first else {
      throw QueryError.malformedResult("expected exactly one column, got \(row.columns.count)")
    }
    return try row.value(column, as: V.self)
  }

  /// Runs a counting query and returns its first value, or `0` when it matched
  /// nothing.
  ///
  /// The query must return a single numeric column, as `RETURN count(n)` does.
  public func matchCount(_ cypher: Cypher) throws -> Int {
    try matchScalar(cypher, as: Int.self) ?? 0
  }
}

/// An edge as returned by a traversal.
///
/// Edge traversals report endpoints and type; edge properties are read with the
/// edge's own accessors.
public struct EdgeSnapshot: Sendable, Equatable, Decodable {
  /// The stable edge identifier, used to read and write edge properties.
  public let id: EdgeID

  /// The source node.
  public let source: NodeID

  /// The target node.
  public let target: NodeID

  /// The edge type.
  public let type: EdgeType

  /// Creates an edge snapshot.
  public init(id: EdgeID, source: NodeID, target: NodeID, type: EdgeType) {
    self.id = id
    self.source = source
    self.target = target
    self.type = type
  }

  private enum CodingKeys: String, CodingKey {
    case id, source, target, type
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(EdgeID.self, forKey: .id) ?? 0
    self.source = try container.decode(NodeID.self, forKey: .source)
    self.target = try container.decode(NodeID.self, forKey: .target)
    self.type = EdgeType(try container.decode(String.self, forKey: .type))
  }
}

/// The native code reported when a node, edge, or property does not exist.
let latticeNotFound: Int32 = -4

/// The native code reported when an operation has no supporting index.
let latticeUnsupported: Int32 = -14

extension Transaction {
  /// Runs a read-only native query inside this transaction and returns its rows
  /// as JSON.
  ///
  /// Unlike ``Database/matchJSON(_:parameters:)`` this observes writes made
  /// earlier in the same transaction. Queries that write are still rejected.
  public func matchJSON(_ cypher: String, parameters: [String: Value] = [:]) throws -> String {
    try withHandle { handle in
      try executeMatchJSON(
        database: database, transaction: handle, cypher: cypher, parameters: parameters)
    }
  }

  /// Runs a read-only native query inside this transaction and returns its rows.
  public func match(_ cypher: Cypher) throws -> [Row] {
    try parseRows(matchJSON(cypher.validated().text, parameters: cypher.parameters))
  }

  /// Runs a read-only native query inside this transaction and decodes each row.
  public func match<T: Decodable>(_ cypher: Cypher, as type: T.Type) throws -> [T] {
    let json = try matchJSON(cypher.validated().text, parameters: cypher.parameters)
    do {
      return try JSONDecoder().decode([T].self, from: Data(json.utf8))
    } catch {
      throw QueryError.malformedResult("\(error)")
    }
  }

  /// Returns a node property as a stored scalar.
  ///
  /// A property that was never set reads as ``Value/null``: the native engine
  /// reports an absent property as not found, which is not an error here.
  public func propertyValue(_ name: String, ofNode node: NodeID) throws -> Value {
    try scalarProperty(name, id: node, reader: lattice_bridge_node_property)
  }

  /// Returns an edge property as a stored scalar.
  public func propertyValue(_ name: String, ofEdge edge: EdgeID) throws -> Value {
    try scalarProperty(name, id: edge, reader: lattice_bridge_edge_property)
  }

  /// Returns a typed node property, or `nil` when it is unset or stored with an
  /// incompatible kind.
  public func property<Owner, V: ValueRepresentable>(
    _ key: PropertyKey<Owner, V>, ofNode node: NodeID
  ) throws -> V? {
    let value = try propertyValue(key.name, ofNode: node)
    if case .null = value { return nil }
    return V(latticeValue: value)
  }

  /// Returns a typed edge property, or `nil` when it is unset or stored with an
  /// incompatible kind.
  public func property<Owner, V: ValueRepresentable>(
    _ key: PropertyKey<Owner, V>, ofEdge edge: EdgeID
  ) throws -> V? {
    let value = try propertyValue(key.name, ofEdge: edge)
    if case .null = value { return nil }
    return V(latticeValue: value)
  }

  /// Removes a property from an edge.
  ///
  /// Nodes have no native property removal; set the property to ``Value/null``
  /// instead.
  public func removeProperty(_ name: String, fromEdge edge: EdgeID) throws {
    try withHandle { handle in
      try name.withCString { try check(lattice_bridge_edge_remove_property(handle, edge, $0)) }
    }
  }

  /// Returns the nodes carrying `label` whose `property` equals `value`.
  ///
  /// This uses the explicit equality index created by
  /// ``Database/createNodeIndex(label:property:)``.
  ///
  /// - Parameters:
  ///   - label: The label the nodes carry.
  ///   - property: The indexed property name.
  ///   - value: The value the property must equal.
  ///   - limit: The most identifiers to return. Pass `nil` for no limit; the
  ///     native lookup rejects a limit of zero, so `nil` sends the maximum.
  /// - Throws: ``GraphPlanError/indexRequired(label:property:)`` when no
  ///   such index exists.
  public func nodeIDs(
    label: String, property: String, equals value: Value, limit: Int? = nil
  ) throws -> [NodeID] {
    let requested = limit.map { $0 > 0 ? $0 : Int.max } ?? Int.max
    return try withHandle { handle in
      var ids: UnsafeMutablePointer<UInt64>?
      var count = 0
      let code = label.withCString { label in
        property.withCString { property in
          withScalarArguments(value) { type, integer, real, boolean, string in
            lattice_bridge_nodes_find_by_property(
              handle, label, property, type, integer, real, boolean, string, requested, &ids,
              &count)
          }
        }
      }
      if code == latticeUnsupported {
        throw GraphPlanError.indexRequired(label: label, property: property)
      }
      try check(code)
      defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }
      return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }
  }

  /// Returns the nodes carrying `type` whose typed `key` equals `value`.
  public func nodeIDs<Owner, V: ValueRepresentable>(
    _ type: NodeType, where key: PropertyKey<Owner, V>, equals value: V, limit: Int? = nil
  ) throws -> [NodeID] {
    try nodeIDs(
      label: type.rawValue, property: key.name, equals: value.latticeValue, limit: limit)
  }

  private func scalarProperty(
    _ name: String, id: UInt64,
    reader: (
      OpaquePointer?, UInt64, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?,
      UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Double>?,
      UnsafeMutablePointer<Bool>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
  ) throws -> Value {
    try withHandle { handle in
      var kind: Int32 = 0
      var integer: Int64 = 0
      var real = 0.0
      var boolean = false
      var string: UnsafeMutablePointer<CChar>?
      let code = name.withCString {
        reader(handle, id, $0, &kind, &integer, &real, &boolean, &string)
      }
      if code == latticeNotFound { return .null }
      try check(code)
      defer { if let string { lattice_bridge_free_buffer(string) } }
      switch kind {
      case 0: return .null
      case 1: return .bool(boolean)
      case 2: return .integer(integer)
      case 3: return .double(real)
      case 4: return .string(string.map { String(cString: $0) } ?? "")
      default:
        throw QueryError.malformedResult("property \(name) is not a scalar")
      }
    }
  }

  /// Returns the edges attached to `node`.
  ///
  /// - Parameters:
  ///   - node: The node to traverse from.
  ///   - outgoing: `true` for outgoing edges, `false` for incoming edges.
  ///   - type: An optional edge type filter.
  public func edges(
    for node: NodeID, outgoing: Bool, type: EdgeType? = nil
  ) throws -> [EdgeSnapshot] {
    let json = try edgesJSON(for: node, outgoing: outgoing, type: type?.rawValue)
    do {
      return try JSONDecoder().decode([EdgeSnapshot].self, from: Data(json.utf8))
    } catch {
      throw QueryError.malformedResult("\(error)")
    }
  }

  /// Returns the nodes reached from `node` over edges of `type`.
  public func neighbors(
    of node: NodeID, outgoing: Bool = true, type: EdgeType? = nil
  ) throws -> [NodeID] {
    try edges(for: node, outgoing: outgoing, type: type).map { outgoing ? $0.target : $0.source }
  }
}

/// Calls `body` with the C representation of a scalar.
///
/// The string pointer is valid only for the duration of the call, matching the
/// borrowed-value contract of the native API.
func withScalarArguments<T>(
  _ value: Value, _ body: (Int32, Int64, Double, Bool, UnsafePointer<CChar>?) -> T
) -> T {
  switch value {
  case .null: return body(0, 0, 0, false, nil)
  case .bool(let value): return body(1, 0, 0, value, nil)
  case .integer(let value): return body(2, value, 0, false, nil)
  case .double(let value): return body(3, 0, value, false, nil)
  case .string(let value): return value.withCString { body(4, 0, 0, false, $0) }
  }
}
