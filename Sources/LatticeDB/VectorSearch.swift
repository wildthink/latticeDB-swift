import Foundation
import LatticeBridge

/// A node matched by a vector query, with its distance from the query vector.
public struct VectorMatch: Sendable, Equatable {
  /// The matched node.
  public let node: NodeID

  /// The distance from the query vector. Nearer neighbors have lower distances,
  /// which is the reverse of ``TextMatch/score``.
  public let distance: Float

  public init(node: NodeID, distance: Float) {
    self.node = node
    self.distance = distance
  }
}

/// An error raised before a vector reaches the native engine.
public enum VectorError: Error, Sendable, Equatable {
  /// A vector was empty, or wider than the 4096-dimension native limit.
  ///
  /// A width that is merely wrong for this database — rather than impossible —
  /// is reported by the engine as ``LatticeError/native(_:)`` instead.
  case invalidDimensions(Int)
}

extension Transaction {
  /// Stores `vector` on `node` under `key`, indexing it for nearest-neighbor
  /// search.
  ///
  /// The database must have been opened with
  /// ``DatabaseConfiguration/vectorDimensions`` set to `vector.count`.
  public func setVector(_ vector: [Float], forKey key: String, onNode node: NodeID) throws {
    try validate(vector)
    try withHandle { handle in
      try key.withCString { key in
        try vector.withUnsafeBufferPointer { buffer in
          try check(
            lattice_bridge_node_set_vector(
              handle, node, key, buffer.baseAddress, UInt32(vector.count)))
        }
      }
    }
  }

  /// Returns the `limit` nearest neighbors of `vector` within this transaction.
  ///
  /// Unlike ``Database/vectorSearch(_:limit:efSearch:)``, this sees vectors
  /// written by this transaction and not yet committed.
  public func vectorSearch(
    _ vector: [Float], limit: Int = 10, efSearch: UInt16 = 0
  ) throws -> [VectorMatch] {
    try validate(vector)
    return try withHandle { handle in
      try executeVectorSearch(
        database: database, transaction: handle, vector: vector, limit: limit, efSearch: efSearch)
    }
  }
}

extension Database {
  /// Returns the `limit` nearest neighbors of `vector`.
  ///
  /// - Parameters:
  ///   - vector: The query vector, which must match the database's stored width.
  ///   - limit: The greatest number of neighbors to return.
  ///   - efSearch: The HNSW search breadth. Larger values trade speed for
  ///     recall; `0` uses the engine default.
  public func vectorSearch(
    _ vector: [Float], limit: Int = 10, efSearch: UInt16 = 0
  ) throws -> [VectorMatch] {
    try validate(vector)
    guard let handle else { throw LatticeError.transactionClosed }
    return try executeVectorSearch(
      database: handle, transaction: nil, vector: vector, limit: limit, efSearch: efSearch)
  }
}

private func validate(_ vector: [Float]) throws {
  guard (1...4096).contains(vector.count) else {
    throw VectorError.invalidDimensions(vector.count)
  }
}

private func executeVectorSearch(
  database: OpaquePointer?, transaction: OpaquePointer?, vector: [Float], limit: Int,
  efSearch: UInt16
) throws -> [VectorMatch] {
  try withMatches { ids, distances, count in
    vector.withUnsafeBufferPointer { buffer in
      lattice_bridge_vector_search(
        database, transaction, buffer.baseAddress, UInt32(vector.count),
        UInt32(clamping: limit), efSearch, ids, distances, count)
    }
  } transform: { VectorMatch(node: $0, distance: $1) }
}
