import Foundation
import LatticeBridge

/// A node matched by a full-text query, with the BM25 score that ranked it.
public struct TextMatch: Sendable, Equatable {
  /// The matched node.
  public let node: NodeID

  /// The BM25 relevance score. Higher scores rank ahead of lower ones.
  public let score: Float

  public init(node: NodeID, score: Float) {
    self.node = node
    self.score = score
  }
}

/// Typo tolerance for a full-text query.
///
/// Terms within the edit distance of an indexed term match it. Text written by
/// the current transaction and not yet committed matches by exact term instead,
/// so a typo does not find a document that transaction has only just written.
public struct FuzzyMatching: Sendable, Equatable {
  /// The greatest Levenshtein edit distance treated as a match, or `nil` for
  /// the engine default of 2.
  public var maximumEditDistance: UInt32?

  /// The shortest term expanded to its near neighbors, or `nil` for the engine
  /// default of 4. Short terms have too many neighbors to expand usefully.
  public var minimumTermLength: UInt32?

  public init(maximumEditDistance: UInt32? = nil, minimumTermLength: UInt32? = nil) {
    self.maximumEditDistance = maximumEditDistance
    self.minimumTermLength = minimumTermLength
  }

  /// Typo tolerance with the engine's default distance and term length.
  public static let `default` = FuzzyMatching()
}

extension Database {
  /// Declares a full-text index over `property` on nodes carrying `label`.
  ///
  /// Searching a label and property with no declared index fails rather than
  /// returning nothing, so a mistyped property name cannot be mistaken for a
  /// query that found no matches.
  ///
  /// Index changes fail while a write transaction is open on this database.
  public func createFullTextIndex(label: String, property: String) throws {
    try fullTextIndex(label, property, create: true, node: true)
  }

  /// Drops the full-text index over `property` on nodes carrying `label`.
  public func dropFullTextIndex(label: String, property: String) throws {
    try fullTextIndex(label, property, create: false, node: true)
  }

  /// Returns whether a full-text index over `property` is declared for `label`.
  public func fullTextIndexExists(label: String, property: String) throws -> Bool {
    try fullTextIndexExists(label, property, node: true)
  }

  /// Declares a full-text index over `property` on edges of `edgeType`.
  public func createFullTextIndex(edgeType: String, property: String) throws {
    try fullTextIndex(edgeType, property, create: true, node: false)
  }

  /// Drops the full-text index over `property` on edges of `edgeType`.
  public func dropFullTextIndex(edgeType: String, property: String) throws {
    try fullTextIndex(edgeType, property, create: false, node: false)
  }

  /// Returns whether a full-text index over `property` is declared for `edgeType`.
  public func fullTextIndexExists(edgeType: String, property: String) throws -> Bool {
    try fullTextIndexExists(edgeType, property, node: false)
  }

  /// Searches a declared full-text index for `query`, ranked by BM25 score.
  ///
  /// - Parameters:
  ///   - query: The text to search for.
  ///   - label: The node label whose index to search.
  ///   - property: The indexed property holding the text.
  ///   - limit: The greatest number of matches to return.
  ///   - fuzzy: Typo tolerance, or `nil` to match terms exactly.
  public func fullTextSearch(
    _ query: String, label: String, property: String, limit: Int = 10,
    fuzzy: FuzzyMatching? = nil
  ) throws -> [TextMatch] {
    guard let handle else { throw LatticeError.transactionClosed }
    return try executeFullTextSearch(
      database: handle, transaction: nil, query: query, label: label, property: property,
      limit: limit, fuzzy: fuzzy)
  }

  private func fullTextIndex(
    _ name: String, _ property: String, create: Bool, node: Bool
  ) throws {
    guard let handle else { throw LatticeError.transactionClosed }
    try name.withCString { name in
      try property.withCString { property in
        try check(lattice_bridge_fts_index(handle, name, property, create, node))
      }
    }
  }

  private func fullTextIndexExists(_ name: String, _ property: String, node: Bool) throws -> Bool {
    guard let handle else { throw LatticeError.transactionClosed }
    var exists = false
    try name.withCString { name in
      try property.withCString { property in
        try check(lattice_bridge_fts_index_exists(handle, name, property, node, &exists))
      }
    }
    return exists
  }
}

extension Transaction {
  /// Searches a declared full-text index for `query` within this transaction.
  ///
  /// Unlike ``Database/fullTextSearch(_:label:property:limit:fuzzy:)``, this
  /// sees text written by this transaction and not yet committed.
  public func fullTextSearch(
    _ query: String, label: String, property: String, limit: Int = 10,
    fuzzy: FuzzyMatching? = nil
  ) throws -> [TextMatch] {
    try withHandle { handle in
      try executeFullTextSearch(
        database: database, transaction: handle, query: query, label: label, property: property,
        limit: limit, fuzzy: fuzzy)
    }
  }
}

private func executeFullTextSearch(
  database: OpaquePointer?, transaction: OpaquePointer?, query: String, label: String,
  property: String, limit: Int, fuzzy: FuzzyMatching?
) throws -> [TextMatch] {
  try withMatches { ids, scores, count in
    label.withCString { label in
      property.withCString { property in
        query.withCString { query in
          lattice_bridge_fts_search(
            database, transaction, label, property, query, UInt32(clamping: limit), fuzzy != nil,
            fuzzy?.maximumEditDistance ?? 0, fuzzy?.minimumTermLength ?? 0, ids, scores, count)
        }
      }
    }
  } transform: { TextMatch(node: $0, score: $1) }
}

/// Runs a native search that returns parallel identifier and score arrays, and
/// pairs them up through `transform`.
func withMatches<T>(
  _ body: (
    UnsafeMutablePointer<UnsafeMutablePointer<UInt64>?>,
    UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
    UnsafeMutablePointer<Int>
  ) -> Int32,
  transform: (NodeID, Float) -> T
) throws -> [T] {
  var ids: UnsafeMutablePointer<UInt64>?
  var scores: UnsafeMutablePointer<Float>?
  var count = 0
  try check(body(&ids, &scores, &count))
  defer { lattice_bridge_free_matches(ids, scores, count) }
  guard let ids, let scores, count > 0 else { return [] }
  return (0..<count).map { transform(ids[$0], scores[$0]) }
}
