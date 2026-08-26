import Foundation
import LatticeBridge

public typealias NodeID = UInt64
public typealias EdgeID = UInt64
public enum Value: Sendable, Equatable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
}
public struct DatabaseConfiguration: Sendable {
  public var createIfMissing = true
  public var readOnly = false
  public init(createIfMissing: Bool = true, readOnly: Bool = false) {
    self.createIfMissing = createIfMissing
    self.readOnly = readOnly
  }
}
public enum LatticeError: Error, Sendable, Equatable {
  case native(Int32)
  case transactionClosed
}

public final class Database {
  private var handle: OpaquePointer?
  public init(path: String, configuration: DatabaseConfiguration = .init()) throws {
    var result: OpaquePointer?
    let code = path.withCString {
      lattice_bridge_open($0, configuration.createIfMissing, configuration.readOnly, &result)
    }
    try check(code)
    handle = result
  }
  deinit { if let handle { _ = lattice_bridge_close(handle) } }
  public func read<T>(_ body: (Transaction) throws -> T) throws -> T { try transact(false, body) }
  public func write<T>(_ body: (Transaction) throws -> T) throws -> T { try transact(true, body) }
  private func transact<T>(_ writable: Bool, _ body: (Transaction) throws -> T) throws -> T {
    guard let handle else { throw LatticeError.transactionClosed }
    var native: OpaquePointer?
    try check(lattice_bridge_begin(handle, writable, &native))
    let transaction = Transaction(native!)
    do {
      let value = try body(transaction)
      try transaction.commit()
      return value
    } catch {
      transaction.rollback()
      throw error
    }
  }
}

public final class Transaction {
  private var handle: OpaquePointer?
  fileprivate init(_ handle: OpaquePointer) { self.handle = handle }
  deinit { rollback() }
  public func createNode(label: String? = nil) throws -> NodeID {
    try withHandle { handle in
      var id: UInt64 = 0
      let code =
        label.map { $0.withCString { lattice_bridge_node_create(handle, $0, &id) } }
        ?? lattice_bridge_node_create(handle, nil, &id)
      try check(code)
      return id
    }
  }
  public func createEdge(from source: NodeID, to target: NodeID, type: String) throws -> EdgeID {
    try withHandle { handle in
      var id: UInt64 = 0
      let code = type.withCString { lattice_bridge_edge_create(handle, source, target, $0, &id) }
      try check(code)
      return id
    }
  }
  public func nodeExists(_ node: NodeID) throws -> Bool {
    try withHandle { handle in
      var exists = false
      try check(lattice_bridge_node_exists(handle, node, &exists))
      return exists
    }
  }
  public func deleteNode(_ node: NodeID) throws {
    try withHandle { try check(lattice_bridge_node_delete($0, node)) }
  }
  public func addLabel(_ label: String, to node: NodeID) throws {
    try withHandle { handle in
      try label.withCString { try check(lattice_bridge_node_add_label(handle, node, $0)) }
    }
  }
  public func removeLabel(_ label: String, from node: NodeID) throws {
    try withHandle { handle in
      try label.withCString { try check(lattice_bridge_node_remove_label(handle, node, $0)) }
    }
  }
  public func deleteEdge(from source: NodeID, to target: NodeID, type: String) throws {
    try withHandle { handle in
      try type.withCString { try check(lattice_bridge_edge_delete(handle, source, target, $0)) }
    }
  }
  public func setProperty(_ key: String, onNode node: NodeID, to value: Value) throws {
    try setScalar(key, id: node, value: value, setter: lattice_bridge_node_set_scalar)
  }
  public func setProperty(_ key: String, onEdge edge: EdgeID, to value: Value) throws {
    try setScalar(key, id: edge, value: value, setter: lattice_bridge_edge_set_scalar)
  }
  public func nodeIDs(label: String) throws -> [NodeID] {
    try withHandle { handle in
      var ids: UnsafeMutablePointer<UInt64>?
      var count = 0
      try label.withCString { try check(lattice_bridge_nodes_with_label(handle, $0, &ids, &count)) }
      defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }
      return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }
  }
  public func labels(of node: NodeID) throws -> [String] {
    try withHandle { handle in
      var string: UnsafeMutablePointer<CChar>?
      try check(lattice_bridge_node_labels(handle, node, &string))
      defer { if let string { lattice_bridge_free_string(string) } }
      guard let string else { return [] }
      return String(cString: string).split(separator: ",").map(String.init)
    }
  }
  private func setScalar(
    _ key: String, id: UInt64, value: Value,
    setter: (
      OpaquePointer?, UInt64, UnsafePointer<CChar>?, Int32, Int64, Double, Bool,
      UnsafePointer<CChar>?
    ) -> Int32
  ) throws {
    try withHandle { handle in
      try key.withCString { key in
        switch value {
        case .null: try check(setter(handle, id, key, 0, 0, 0, false, nil))
        case .bool(let value): try check(setter(handle, id, key, 1, 0, 0, value, nil))
        case .integer(let value): try check(setter(handle, id, key, 2, value, 0, false, nil))
        case .double(let value): try check(setter(handle, id, key, 3, 0, value, false, nil))
        case .string(let value):
          try value.withCString { try check(setter(handle, id, key, 4, 0, 0, false, $0)) }
        }
      }
    }
  }
  public func commit() throws {
    guard let handle else { throw LatticeError.transactionClosed }
    self.handle = nil
    try check(lattice_bridge_commit(handle))
  }
  public func rollback() {
    guard let handle else { return }
    self.handle = nil
    _ = lattice_bridge_rollback(handle)
  }
  private func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    guard let handle else { throw LatticeError.transactionClosed }
    return try body(handle)
  }
}
public enum LatticeDB { public static let nativeVersion = "0.12.0" }
extension Database {
  public func matchJSON(_ cypher: String, parameters: [String: Value] = [:]) throws -> String {
    guard let handle else { throw LatticeError.transactionClosed }
    let orderedParameters = parameters.sorted { $0.key < $1.key }
    let names = orderedParameters.map { Array($0.key.utf8CString) }
    let strings = orderedParameters.map { parameter -> [CChar] in
      guard case .string(let value) = parameter.value else { return [] }
      return Array(value.utf8CString)
    }

    return try withCStringPointers(names) { namePointers in
      try withCStringPointers(strings) { stringPointers in
        let bridgeParameters = orderedParameters.indices.map { index in
          bridgeParameter(
            name: namePointers[index],
            value: orderedParameters[index].value,
            string: stringPointers[index]
          )
        }
        return try bridgeParameters.withUnsafeBufferPointer { parameters in
          var output: UnsafeMutablePointer<CChar>?
          let code = cypher.withCString {
            lattice_bridge_match_json_parameters(
              handle, $0, parameters.baseAddress, parameters.count, &output)
          }
          try check(code)
          guard let output else { return "[]" }
          defer { lattice_bridge_free_json(output) }
          return String(cString: output)
        }
      }
    }
  }
}
extension Transaction {
  public func allNodeIDs() throws -> [NodeID] {
    try withHandle { handle in
      var ids: UnsafeMutablePointer<UInt64>?
      var count = 0
      try check(lattice_bridge_all_node_ids(handle, &ids, &count))
      defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }
      return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }
  }
  public func nodePropertyJSON(_ key: String, of node: NodeID) throws -> String {
    try withHandle { handle in
      var output: UnsafeMutablePointer<CChar>?
      let code = key.withCString { lattice_bridge_node_property_json(handle, node, $0, &output) }
      try check(code)
      guard let output else { return "null" }
      defer { lattice_bridge_free_json(output) }
      return String(cString: output)
    }
  }
  public func edgesJSON(for node: NodeID, outgoing: Bool, type: String? = nil) throws -> String {
    try withHandle { handle in
      var output: UnsafeMutablePointer<CChar>?
      let code =
        type.map {
          $0.withCString { lattice_bridge_edges_json(handle, node, outgoing, $0, &output) }
        } ?? lattice_bridge_edges_json(handle, node, outgoing, nil, &output)
      try check(code)
      guard let output else { return "[]" }
      defer { lattice_bridge_free_json(output) }
      return String(cString: output)
    }
  }
}
extension Database {
  public func nodeTypes() throws -> [String] {
    try read { transaction in
      var types = Set<String>()
      for node in try transaction.allNodeIDs() { types.formUnion(try transaction.labels(of: node)) }
      return types.sorted()
    }
  }
}
extension Database {
  public func createNodeIndex(label: String, property: String) throws {
    try index(label, property, create: true, operation: lattice_bridge_node_index)
  }
  public func dropNodeIndex(label: String, property: String) throws {
    try index(label, property, create: false, operation: lattice_bridge_node_index)
  }
  public func createEdgeIndex(type: String, property: String) throws {
    try index(type, property, create: true, operation: lattice_bridge_edge_index)
  }
  public func dropEdgeIndex(type: String, property: String) throws {
    try index(type, property, create: false, operation: lattice_bridge_edge_index)
  }
  private func index(
    _ kind: String, _ property: String, create: Bool,
    operation: (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool) -> Int32
  ) throws {
    guard let handle else { throw LatticeError.transactionClosed }
    let code = kind.withCString { kind in
      property.withCString { property in operation(handle, kind, property, create) }
    }
    try check(code)
  }
}
extension Database {
  public func nodeSummaryJSON(_ node: NodeID) throws -> String {
    try read { transaction in
      guard try transaction.nodeExists(node) else { throw LatticeError.native(-4) }
      let labels = try JSONEncoder().encode(try transaction.labels(of: node))
      let labelJSON = String(decoding: labels, as: UTF8.self)
      let outgoing = try transaction.edgesJSON(for: node, outgoing: true)
      let incoming = try transaction.edgesJSON(for: node, outgoing: false)
      return
        "{\"id\":\(node),\"labels\":\(labelJSON),\"outgoing\":\(outgoing),\"incoming\":\(incoming)}"
    }
  }
}

public enum ValueKind: String, Sendable, Equatable {
  case null, bool, integer, double, string

  fileprivate init(_ value: Value) {
    switch value {
    case .null: self = .null
    case .bool: self = .bool
    case .integer: self = .integer
    case .double: self = .double
    case .string: self = .string
    }
  }
}

public struct PropertyRule: Sendable, Equatable {
  public let kind: ValueKind
  public let required: Bool
  public let allowsNull: Bool

  public init(kind: ValueKind, required: Bool = false, allowsNull: Bool = false) {
    self.kind = kind
    self.required = required
    self.allowsNull = allowsNull
  }
}

public struct NodeSchema: Sendable, Equatable {
  public let label: String
  public let properties: [String: PropertyRule]
  public let allowsAdditionalProperties: Bool

  public init(
    label: String, properties: [String: PropertyRule] = [:], allowsAdditionalProperties: Bool = true
  ) {
    self.label = label
    self.properties = properties
    self.allowsAdditionalProperties = allowsAdditionalProperties
  }
}

public struct EdgeSchema: Sendable, Equatable {
  public let type: String
  public let properties: [String: PropertyRule]
  public let allowsAdditionalProperties: Bool

  public init(
    type: String, properties: [String: PropertyRule] = [:], allowsAdditionalProperties: Bool = true
  ) {
    self.type = type
    self.properties = properties
    self.allowsAdditionalProperties = allowsAdditionalProperties
  }
}

public enum SchemaValidationError: Error, Sendable, Equatable {
  case unknownNodeLabel(String)
  case unknownEdgeType(String)
  case missingRequiredProperty(entity: String, property: String)
  case unexpectedProperty(entity: String, property: String)
  case invalidPropertyType(entity: String, property: String, expected: ValueKind, actual: ValueKind)
}

public struct GraphSchema: Sendable, Equatable {
  private let nodes: [String: NodeSchema]
  private let edges: [String: EdgeSchema]

  public init(nodes: [NodeSchema] = [], edges: [EdgeSchema] = []) {
    self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.label, $0) })
    self.edges = Dictionary(uniqueKeysWithValues: edges.map { ($0.type, $0) })
  }

  public func validateNode(label: String, properties: [String: Value]) throws {
    guard let schema = nodes[label] else { throw SchemaValidationError.unknownNodeLabel(label) }
    try validate(
      entity: label, properties: properties, rules: schema.properties,
      allowsAdditionalProperties: schema.allowsAdditionalProperties)
  }

  public func validateEdge(type: String, properties: [String: Value]) throws {
    guard let schema = edges[type] else { throw SchemaValidationError.unknownEdgeType(type) }
    try validate(
      entity: type, properties: properties, rules: schema.properties,
      allowsAdditionalProperties: schema.allowsAdditionalProperties)
  }

  private func validate(
    entity: String, properties: [String: Value], rules: [String: PropertyRule],
    allowsAdditionalProperties: Bool
  ) throws {
    for (name, rule) in rules where rule.required && properties[name] == nil {
      throw SchemaValidationError.missingRequiredProperty(entity: entity, property: name)
    }
    for (name, value) in properties {
      guard let rule = rules[name] else {
        if !allowsAdditionalProperties {
          throw SchemaValidationError.unexpectedProperty(entity: entity, property: name)
        }
        continue
      }
      let actual = ValueKind(value)
      if actual == .null && rule.allowsNull { continue }
      guard actual == rule.kind else {
        throw SchemaValidationError.invalidPropertyType(
          entity: entity, property: name, expected: rule.kind, actual: actual)
      }
    }
  }
}

extension GraphSchema {
  public func createNode(in transaction: Transaction, label: String, properties: [String: Value])
    throws -> NodeID
  {
    try validateNode(label: label, properties: properties)
    let node = try transaction.createNode(label: label)
    try transaction.setProperties(properties, onNode: node)
    return node
  }

  public func createEdge(
    in transaction: Transaction, from source: NodeID, to target: NodeID, type: String,
    properties: [String: Value]
  ) throws -> EdgeID {
    try validateEdge(type: type, properties: properties)
    let edge = try transaction.createEdge(from: source, to: target, type: type)
    try transaction.setProperties(properties, onEdge: edge)
    return edge
  }
}

extension Transaction {
  public func setProperties(_ properties: [String: Value], onNode node: NodeID) throws {
    for (key, value) in properties { try setProperty(key, onNode: node, to: value) }
  }

  public func setProperties(_ properties: [String: Value], onEdge edge: EdgeID) throws {
    for (key, value) in properties { try setProperty(key, onEdge: edge, to: value) }
  }
}

public enum TemporalValidityError: Error, Sendable, Equatable {
  case endBeforeStart
}

public enum TemporalQueryError: Error, Sendable, Equatable {
  case invalidIdentifier(String)
}

/// An optional application-level valid-time convention, stored as epoch milliseconds.
/// It does not provide historical storage snapshots; it qualifies the current graph data.
public struct TemporalValidity: Sendable, Equatable {
  public let validFrom: Date
  public let validTo: Date?

  public init(validFrom: Date, validTo: Date? = nil) throws {
    guard validTo.map({ $0 >= validFrom }) ?? true else {
      throw TemporalValidityError.endBeforeStart
    }
    self.validFrom = validFrom
    self.validTo = validTo
  }

  public func contains(_ date: Date) -> Bool {
    date >= validFrom && validTo.map { date < $0 } != false
  }

  public func propertyValues(fromKey: String = "validFrom", toKey: String = "validTo") -> [String:
    Value]
  {
    var properties: [String: Value] = [fromKey: .integer(epochMilliseconds(validFrom))]
    properties[toKey] = validTo.map { .integer(epochMilliseconds($0)) } ?? .null
    return properties
  }
}

/// A Cypher predicate and parameter set for querying currently stored valid-time data.
/// This qualifies records by their application-level interval; it is not a historical snapshot.
public struct TemporalAsOf: Sendable, Equatable {
  public let date: Date
  public let fromKey: String
  public let toKey: String
  public let parameter: String

  public init(
    date: Date, fromKey: String = "validFrom", toKey: String = "validTo", parameter: String = "asOf"
  ) throws {
    for identifier in [fromKey, toKey, parameter] { try validateCypherIdentifier(identifier) }
    self.date = date
    self.fromKey = fromKey
    self.toKey = toKey
    self.parameter = parameter
  }

  public var parameters: [String: Value] {
    [parameter: .integer(epochMilliseconds(date))]
  }

  public func predicate(for variable: String) throws -> String {
    try validateCypherIdentifier(variable)
    return
      "\(variable).\(fromKey) <= $\(parameter) AND (\(variable).\(toKey) IS NULL OR \(variable).\(toKey) > $\(parameter))"
  }
}

extension Transaction {
  public func setTemporalValidity(
    _ validity: TemporalValidity, onNode node: NodeID, fromKey: String = "validFrom",
    toKey: String = "validTo"
  ) throws {
    try setProperties(validity.propertyValues(fromKey: fromKey, toKey: toKey), onNode: node)
  }

  public func setTemporalValidity(
    _ validity: TemporalValidity, onEdge edge: EdgeID, fromKey: String = "validFrom",
    toKey: String = "validTo"
  ) throws {
    try setProperties(validity.propertyValues(fromKey: fromKey, toKey: toKey), onEdge: edge)
  }
}

private func epochMilliseconds(_ date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func validateCypherIdentifier(_ identifier: String) throws {
  guard !identifier.isEmpty,
    identifier.unicodeScalars.allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) })
  else {
    throw TemporalQueryError.invalidIdentifier(identifier)
  }
}
private func check(_ code: Int32) throws {
  guard code == 0 else { throw LatticeError.native(code) }
}

private func bridgeParameter(
  name: UnsafePointer<CChar>?, value: Value, string: UnsafePointer<CChar>?
) -> lattice_bridge_parameter {
  var parameter = lattice_bridge_parameter()
  parameter.name = name
  switch value {
  case .null: parameter.type = 0
  case .bool(let value):
    parameter.type = 1
    parameter.boolean = value
  case .integer(let value):
    parameter.type = 2
    parameter.integer = value
  case .double(let value):
    parameter.type = 3
    parameter.real = value
  case .string:
    parameter.type = 4
    parameter.string = string
  }
  return parameter
}

private func withCStringPointers<T>(
  _ strings: [[CChar]], _ body: ([UnsafePointer<CChar>?]) throws -> T
) rethrows -> T {
  guard let first = strings.first else { return try body([]) }
  return try first.withUnsafeBufferPointer { firstPointer in
    try withCStringPointers(Array(strings.dropFirst())) { remainingPointers in
      try body([firstPointer.baseAddress] + remainingPointers)
    }
  }
}
