import Foundation
import LatticeDB

// MARK: - Facet

/// A typed reference a record is about: a person, a project, a place, a tool.
///
/// Facets are what a record *concerns*, as opposed to what it *says*. Ranking on
/// them is exact rather than lexical: a record tagged `Facet("person", "sam")`
/// matches a query for that person whether or not the text spells the name, and
/// a record that merely mentions the word does not match unless it was tagged.
///
/// Both halves are yours to choose. Nothing in this library interprets a kind.
public struct Facet: Hashable, Sendable, Codable, CustomStringConvertible {
  /// What sort of thing this refers to, such as `"person"` or `"project"`.
  public var kind: String

  /// Which one, within that kind.
  public var id: String

  public init(_ kind: String, _ id: String) {
    self.kind = kind
    self.id = id
  }

  public var description: String { "\(kind):\(id)" }
}

/// How much each kind of facet counts when ranking.
///
/// Weights are relative and have no scale: a record matching a kind weighted 4
/// outranks one matching a kind weighted 2, and nothing else follows from the
/// numbers. Kinds not named here count ``FacetWeights/default`` each.
public struct FacetWeights: Sendable, Equatable, ExpressibleByDictionaryLiteral {
  /// Weights by facet kind.
  public var byKind: [String: Double]

  /// What a kind counts when it is not named in ``byKind``.
  public var `default`: Double

  public init(byKind: [String: Double] = [:], default: Double = 1) {
    self.byKind = byKind
    self.default = `default`
  }

  public init(dictionaryLiteral elements: (String, Double)...) {
    self.init(byKind: Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }

  /// The weight for `kind`.
  public func weight(of kind: String) -> Double { byKind[kind] ?? `default` }

  /// Every kind counting the same.
  public static let uniform = FacetWeights(byKind: [:])
}

// MARK: - Reading

extension MemoryStore {
  /// Returns the facets `record` is tagged with.
  ///
  /// - Throws: ``MemoryError/unknownRecord(_:)`` when the store holds no such
  ///   evidence or assertion.
  public func facets(of record: RecordID) throws -> Set<Facet> {
    try database.read { transaction in
      guard let node = try locateRecord(record, in: transaction) else {
        throw MemoryError.unknownRecord(record)
      }
      return try facets(ofNode: node, in: transaction)
    }
  }

  /// Returns the identifiers of every record tagged with any of `facets`,
  /// newest first.
  ///
  /// This is the traversal the tags exist for — everything concerning one
  /// person, one project — and it answers from the graph rather than from a
  /// ranking, so it is exact and unbudgeted. Use
  /// ``RetrievalRequest/facets`` when you want them ranked alongside a query
  /// instead.
  public func records(mentioning facets: Set<Facet>) throws -> [RecordID] {
    guard !facets.isEmpty else { return [] }
    return try database.read { transaction in
      var found: Set<NodeID> = []
      for facet in facets {
        found.formUnion(try nodesMentioning(facet, in: transaction))
      }
      return
        try found
        .map { (node: $0, id: RecordID(try string(Keys.id, $0, in: transaction, fallback: ""))) }
        .sorted { $0.node > $1.node }
        .map(\.id)
    }
  }

  /// Reads the facets attached to one node.
  func facets(ofNode node: NodeID, in transaction: Transaction) throws -> Set<Facet> {
    var facets: Set<Facet> = []
    for target in try transaction.neighbors(
      of: node, outgoing: true, type: EdgeType(Edges.mentions))
    {
      facets.insert(
        Facet(
          try string(Keys.facetKind, target, in: transaction, fallback: ""),
          try string(Keys.facetID, target, in: transaction, fallback: "")))
    }
    return facets
  }

  /// Finds the evidence or assertion node holding `record`.
  private func locateRecord(_ record: RecordID, in transaction: Transaction) throws -> NodeID? {
    if let node = try locate(record, label: Labels.evidence, in: transaction) { return node }
    return try locate(record, label: Labels.assertion, in: transaction)
  }
}

// MARK: - Writing

extension MemoryStore {
  /// Attaches `facets` to `node`, creating any facet the store has not seen.
  ///
  /// One node per facet is shared by every record tagged with it, which is what
  /// makes ``records(mentioning:)`` a traversal rather than a scan. Attaching a
  /// facet a node already carries adds nothing.
  func attach(_ facets: Set<Facet>, to node: NodeID, in transaction: Transaction) throws {
    guard !facets.isEmpty else { return }
    let existing = try self.facets(ofNode: node, in: transaction)
    for facet in facets.sorted(by: { $0.description < $1.description }) {
      guard !existing.contains(facet) else { continue }
      let target = try facetNode(facet, in: transaction) ?? {
        let created = try transaction.createNode(label: Labels.facet)
        try transaction.setProperty(Keys.facetKind, onNode: created, to: .string(facet.kind))
        try transaction.setProperty(Keys.facetID, onNode: created, to: .string(facet.id))
        return created
      }()
      _ = try transaction.createEdge(from: node, to: target, type: Edges.mentions)
    }
  }

  /// Removes every facet from `node`, and any facet left tagging nothing.
  ///
  /// What a record was about is as revealing as what it said, so a tombstone
  /// keeps neither. Pruning the facet itself matters for the same reason: a
  /// `person:sam` node with no records left still says Sam was once here.
  func detachFacets(from node: NodeID, in transaction: Transaction) throws {
    let targets = try transaction.neighbors(
      of: node, outgoing: true, type: EdgeType(Edges.mentions))
    for target in targets {
      try transaction.deleteEdge(from: node, to: target, type: Edges.mentions)
      let remaining = try transaction.neighbors(
        of: target, outgoing: false, type: EdgeType(Edges.mentions))
      if remaining.isEmpty { try transaction.deleteNode(target) }
    }
  }

  /// Returns the record nodes tagged with `facet`.
  ///
  /// One lookup for the facet's own node, then its incoming edges: the cost
  /// follows how many records carry the facet, not how many the store holds.
  func nodesMentioning(_ facet: Facet, in transaction: Transaction) throws -> [NodeID] {
    guard let node = try facetNode(facet, in: transaction) else { return [] }
    return try transaction.neighbors(
      of: node, outgoing: false, type: EdgeType(Edges.mentions))
  }

  /// Finds the shared node for `facet`.
  ///
  /// The identifier is indexed and the kind is checked afterwards, so two kinds
  /// may use the same identifier without colliding.
  private func facetNode(_ facet: Facet, in transaction: Transaction) throws -> NodeID? {
    for node in try transaction.nodeIDs(
      label: Labels.facet, property: Keys.facetID, equals: .string(facet.id))
    where try transaction.propertyValue(Keys.facetKind, ofNode: node) == .string(facet.kind) {
      return node
    }
    return nil
  }
}
