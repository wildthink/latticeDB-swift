import Foundation
import LatticeBridge

/// The stable identifier assigned to a graph node.
public typealias NodeID = UInt64

/// The stable identifier assigned to a graph edge.
public typealias EdgeID = UInt64

/// A scalar value stored in a node or edge property, or bound to a native query.
public enum Value: Sendable, Equatable {
  /// The absence of a value.
  case null
  /// A Boolean value.
  case bool(Bool)
  /// A signed 64-bit integer.
  case integer(Int64)
  /// A double-precision floating-point number.
  case double(Double)
  /// A UTF-8 string.
  case string(String)
}

/// Options that control how a database is opened.
public struct DatabaseConfiguration: Sendable {
  /// Whether to create the database file when it does not exist.
  public var createIfMissing = true

  /// Whether to prevent all writes through the opened database handle.
  public var readOnly = false

  /// Creates database open options.
  ///
  /// - Parameters:
  ///   - createIfMissing: Whether a missing database path is created.
  ///   - readOnly: Whether the resulting handle prohibits writes.
  public init(createIfMissing: Bool = true, readOnly: Bool = false) {
    self.createIfMissing = createIfMissing
    self.readOnly = readOnly
  }
}

/// An error returned by LatticeDB or by a closed transaction.
public enum LatticeError: Error, Sendable, Equatable {
  /// A native LatticeDB error code.
  case native(Int32)

  /// An operation was attempted after a transaction committed or rolled back.
  case transactionClosed
}

/// An opened LatticeDB database.
///
/// Use ``read(_:)`` and ``write(_:)`` to scope transaction lifetimes. The
/// database closes automatically when this object is released.
public final class Database {
  var handle: OpaquePointer?

  /// Opens a database at `path`.
  ///
  /// - Parameters:
  ///   - path: The filesystem path of the database.
  ///   - configuration: Options controlling creation and write access.
  public init(path: String, configuration: DatabaseConfiguration = .init()) throws {
    var result: OpaquePointer?
    let code = path.withCString {
      lattice_bridge_open($0, configuration.createIfMissing, configuration.readOnly, &result)
    }
    try check(code)
    handle = result
  }

  deinit {
    if let handle { _ = lattice_bridge_close(handle) }
  }

  /// Runs `body` in a read-only transaction.
  ///
  /// The transaction commits when `body` returns and rolls back if it throws.
  public func read<T>(_ body: (Transaction) throws -> T) throws -> T {
    try transact(false, body)
  }

  /// Runs `body` in a read-write transaction.
  ///
  /// The transaction commits when `body` returns and rolls back if it throws.
  public func write<T>(_ body: (Transaction) throws -> T) throws -> T {
    try transact(true, body)
  }

  private func transact<T>(_ writable: Bool, _ body: (Transaction) throws -> T) throws -> T {
    guard let handle else { throw LatticeError.transactionClosed }
    var native: OpaquePointer?
    try check(lattice_bridge_begin(handle, writable, &native))
    let transaction = Transaction(native!, database: handle)
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

/// A scoped read or write transaction.
///
/// Transactions are supplied by ``Database/read(_:)`` and
/// ``Database/write(_:)``. Do not retain them beyond the closure that receives
/// them.
public final class Transaction {
  private var handle: OpaquePointer?

  /// The database this transaction belongs to, needed to prepare native queries.
  let database: OpaquePointer?

  fileprivate init(_ handle: OpaquePointer, database: OpaquePointer?) {
    self.handle = handle
    self.database = database
  }

  deinit { rollback() }

  /// Creates a node, optionally with an initial label.
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

  /// Creates an edge from `source` to `target` with `type`.
  public func createEdge(from source: NodeID, to target: NodeID, type: String) throws -> EdgeID {
    try withHandle { handle in
      var id: UInt64 = 0
      let code = type.withCString { lattice_bridge_edge_create(handle, source, target, $0, &id) }
      try check(code)
      return id
    }
  }

  /// Returns whether `node` exists in this transaction's view of the graph.
  public func nodeExists(_ node: NodeID) throws -> Bool {
    try withHandle { handle in
      var exists = false
      try check(lattice_bridge_node_exists(handle, node, &exists))
      return exists
    }
  }

  /// Deletes a node and its associated graph state.
  public func deleteNode(_ node: NodeID) throws {
    try withHandle { try check(lattice_bridge_node_delete($0, node)) }
  }

  /// Adds `label` to `node`.
  public func addLabel(_ label: String, to node: NodeID) throws {
    try withHandle { handle in
      try label.withCString { try check(lattice_bridge_node_add_label(handle, node, $0)) }
    }
  }

  /// Removes `label` from `node`.
  public func removeLabel(_ label: String, from node: NodeID) throws {
    try withHandle { handle in
      try label.withCString { try check(lattice_bridge_node_remove_label(handle, node, $0)) }
    }
  }

  /// Deletes the edge identified by its source, target, and type.
  public func deleteEdge(from source: NodeID, to target: NodeID, type: String) throws {
    try withHandle { handle in
      try type.withCString { try check(lattice_bridge_edge_delete(handle, source, target, $0)) }
    }
  }

  /// Sets a scalar property on a node.
  public func setProperty(_ key: String, onNode node: NodeID, to value: Value) throws {
    try setScalar(key, id: node, value: value, setter: lattice_bridge_node_set_scalar)
  }

  /// Sets a scalar property on an edge.
  public func setProperty(_ key: String, onEdge edge: EdgeID, to value: Value) throws {
    try setScalar(key, id: edge, value: value, setter: lattice_bridge_edge_set_scalar)
  }

  /// Returns all node identifiers carrying `label`.
  public func nodeIDs(label: String) throws -> [NodeID] {
    try withHandle { handle in
      var ids: UnsafeMutablePointer<UInt64>?
      var count = 0
      try label.withCString { try check(lattice_bridge_nodes_with_label(handle, $0, &ids, &count)) }
      defer { if let ids { lattice_bridge_free_node_ids(ids, count) } }
      return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }
  }

  /// Returns the labels assigned to `node`.
  public func labels(of node: NodeID) throws -> [String] {
    try withHandle { handle in
      var string: UnsafeMutablePointer<CChar>?
      try check(lattice_bridge_node_labels(handle, node, &string))
      defer { if let string { lattice_bridge_free_string(string) } }
      guard let string else { return [] }
      return String(cString: string).split(separator: ",").map(String.init)
    }
  }

  /// Commits this transaction and closes it.
  public func commit() throws {
    guard let handle else { throw LatticeError.transactionClosed }
    self.handle = nil
    try check(lattice_bridge_commit(handle))
  }

  /// Rolls back this transaction when it is still open.
  public func rollback() {
    guard let handle else { return }
    self.handle = nil
    _ = lattice_bridge_rollback(handle)
  }

  func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    guard let handle else { throw LatticeError.transactionClosed }
    return try body(handle)
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
}

/// Metadata for the LatticeDB native engine bundled by this package.
public enum LatticeDB {
  /// The pinned native LatticeDB semantic version.
  public static let nativeVersion = "0.15.0"
}

func check(_ code: Int32) throws {
  guard code == 0 else { throw LatticeError.native(code) }
}
