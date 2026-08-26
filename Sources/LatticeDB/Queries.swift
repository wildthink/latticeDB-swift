import Foundation
import LatticeBridge

extension Database {
  /// Executes a read-only native Cypher query and returns its rows as JSON.
  ///
  /// Bind untrusted values with `parameters`; parameter names omit the `$`
  /// prefix used in Cypher. Queries that can write are rejected.
  public func matchJSON(_ cypher: String, parameters: [String: Value] = [:]) throws -> String {
    guard let handle else { throw LatticeError.transactionClosed }
    return try executeMatchJSON(
      database: handle, transaction: nil, cypher: cypher, parameters: parameters)
  }

  /// Returns the distinct labels currently assigned to at least one node.
  public func nodeTypes() throws -> [String] {
    try read { transaction in
      var types = Set<String>()
      for node in try transaction.allNodeIDs() { types.formUnion(try transaction.labels(of: node)) }
      return types.sorted()
    }
  }

  /// Creates an equality index for `property` on nodes with `label`.
  public func createNodeIndex(label: String, property: String) throws {
    try index(label, property, create: true, operation: lattice_bridge_node_index)
  }

  /// Drops an equality index for `property` on nodes with `label`.
  public func dropNodeIndex(label: String, property: String) throws {
    try index(label, property, create: false, operation: lattice_bridge_node_index)
  }

  /// Creates an equality index for `property` on edges with `type`.
  public func createEdgeIndex(type: String, property: String) throws {
    try index(type, property, create: true, operation: lattice_bridge_edge_index)
  }

  /// Drops an equality index for `property` on edges with `type`.
  public func dropEdgeIndex(type: String, property: String) throws {
    try index(type, property, create: false, operation: lattice_bridge_edge_index)
  }

  /// Returns a JSON object containing a node's labels and incoming/outgoing edges.
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

extension Transaction {
  /// Returns every node identifier visible in this transaction.
  public func allNodeIDs() throws -> [NodeID] {
    try withHandle { handle in
      var ids: UnsafeMutablePointer<UInt64>?
      var count = 0
      try check(lattice_bridge_all_node_ids(handle, &ids, &count))
      defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }
      return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }
  }

  /// Returns a node property's scalar value encoded as JSON.
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

  /// Returns incoming or outgoing edges for `node` encoded as JSON.
  ///
  /// - Parameters:
  ///   - node: The node whose edges are returned.
  ///   - outgoing: `true` for outgoing edges and `false` for incoming edges.
  ///   - type: An optional edge type filter.
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

/// Runs a native read-only query and returns its rows as JSON.
///
/// When `transaction` is `nil` the bridge opens its own read-only transaction;
/// otherwise the query executes inside the supplied transaction and observes its
/// uncommitted writes.
func executeMatchJSON(
  database: OpaquePointer?, transaction: OpaquePointer?, cypher: String,
  parameters: [String: Value]
) throws -> String {
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
        let code = cypher.withCString { cypher in
          if let transaction {
            lattice_bridge_match_json_txn(
              database, transaction, cypher, parameters.baseAddress, parameters.count, &output)
          } else {
            lattice_bridge_match_json_parameters(
              database, cypher, parameters.baseAddress, parameters.count, &output)
          }
        }
        try check(code)
        guard let output else { return "[]" }
        defer { lattice_bridge_free_json(output) }
        return String(cString: output)
      }
    }
  }
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
