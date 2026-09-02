import Foundation
import LatticeDB

/// A store of evidence and the assertions derived from it.
///
/// The store owns every mutation. Callers hand it raw evidence; extractors
/// suggest what to derive; the store decides what is actually written, using the
/// ``MemorySchema`` it was opened with. See <doc:EvidenceAndAssertions>.
///
/// ```swift
/// let store = try MemoryStore(
///   path: "memory.db",
///   schema: ["package.manager": SlotRule(allowedValues: ["npm", "pnpm", "yarn"])],
///   extractors: [PatternExtractor([...])]
/// )
///
/// try store.record(EvidenceDraft(text: "We switched to pnpm.", scope: ["project": "acme"]))
/// let current = try store.currentAssertions(in: ["project": "acme"])
/// ```
///
/// A store is a thin layer over one `Database`, which stays
/// available as ``database`` — the graph is ordinary nodes and edges, and
/// nothing stops you querying it directly.
public final class MemoryStore {
  /// The underlying database.
  ///
  /// Use it for Cypher over the stored graph, or to keep unrelated nodes in the
  /// same file. Writing to this library's own labels behind its back is what
  /// ``MemoryError/malformedRecord(_:_:)`` reports.
  public let database: Database

  /// The slots this store accepts, and the rules each is held to.
  public let schema: MemorySchema

  /// The extractors run over every recorded piece of evidence, in order.
  public var extractors: [any Extractor]

  /// Turns stored text into vectors, enabling ``SearchMode/vector`` and
  /// ``SearchMode/hybrid`` retrieval.
  ///
  /// With no embedder, records are stored without vectors and retrieval falls
  /// back to lexical ranking. Adding one later does not embed what is already
  /// stored.
  public let embedder: (any TextEmbedder)?

  /// The clock the store reads for recording times and default valid-from
  /// times. Replace it to make ingest reproducible in tests.
  public var clock: @Sendable () -> Date = { Date() }


  /// Opens a store over an existing database.
  ///
  /// This declares the indexes the store needs, which is idempotent: opening an
  /// existing store again is safe and changes nothing.
  /// When an `embedder` is given, `database` must have been opened with
  /// `DatabaseConfiguration.vectorDimensions` equal to the
  /// embedder's width. The path-based initializer arranges that for you.
  public init(
    database: Database, schema: MemorySchema, extractors: [any Extractor] = [],
    embedder: (any TextEmbedder)? = nil
  ) throws {
    self.database = database
    self.schema = schema
    self.extractors = extractors
    self.embedder = embedder
    try installIndexes()
  }

  /// Opens a store over a database at `path`, creating it when missing.
  ///
  /// An `embedder` sets the database's vector width to match it. A store opened
  /// once with an embedder must be opened with the same width every time after,
  /// because the width is recorded in the file.
  public convenience init(
    path: String, schema: MemorySchema, extractors: [any Extractor] = [],
    embedder: (any TextEmbedder)? = nil, configuration: DatabaseConfiguration = .init()
  ) throws {
    var configuration = configuration
    if let embedder { configuration.vectorDimensions = embedder.dimensions }
    try self.init(
      database: try Database(path: path, configuration: configuration), schema: schema,
      extractors: extractors, embedder: embedder)
  }

  private func installIndexes() throws {
    try database.createNodeIndex(label: Labels.evidence, property: Keys.id)
    try database.createNodeIndex(label: Labels.assertion, property: Keys.id)
    try database.createNodeIndex(label: Labels.assertion, property: Keys.slot)
    try database.createFullTextIndex(label: Labels.evidence, property: Keys.text)
    try database.createFullTextIndex(label: Labels.assertion, property: Keys.text)
  }


  // MARK: - Reading

  /// Returns the evidence with `id`, or `nil` when the store holds none.
  public func evidence(_ id: RecordID) throws -> Evidence? {
    try database.read { transaction in
      guard let node = try locate(id, label: Labels.evidence, in: transaction) else { return nil }
      return try readEvidence(node, in: transaction)
    }
  }

  /// Returns the assertion with `id`, or `nil` when the store holds none.
  public func assertion(_ id: RecordID) throws -> Assertion? {
    try database.read { transaction in
      guard let node = try locate(id, label: Labels.assertion, in: transaction) else { return nil }
      return try readAssertion(node, in: transaction)
    }
  }

  /// Returns the current assertions visible in `scope`.
  ///
  /// Visibility follows ``Scope/isVisible(in:)``: an assertion appears only when
  /// every dimension it declares is present in `scope` with the same value.
  ///
  /// Passing a `slot` uses an index; omitting it reads every assertion in the
  /// store and filters in memory, which is fine for thousands of assertions and
  /// not for millions.
  ///
  /// - Parameters:
  ///   - scope: The querying context.
  ///   - slot: One slot to restrict to, or `nil` for every slot.
  ///   - category: One ``SlotRule/category`` to restrict to, or `nil` for all.
  public func currentAssertions(
    in scope: Scope, slot: Slot? = nil, category: String? = nil
  ) throws -> [Assertion] {
    try assertions(in: scope, slot: slot, category: category) { $0.state == .current }
  }

  /// Returns the assertions that held at `date`, whether or not they still do.
  ///
  /// This is the historical read: it answers "what did this store hold to be
  /// true then", using each assertion's own valid interval rather than when the
  /// row happened to be written.
  public func assertions(
    validAt date: Date, in scope: Scope, slot: Slot? = nil, category: String? = nil
  ) throws -> [Assertion] {
    try assertions(in: scope, slot: slot, category: category) { $0.held(at: date) }
  }

  /// Returns every assertion ever written for `slot` in `scope`, newest first.
  ///
  /// Superseded and retracted assertions are included; this is the audit trail
  /// for one slot.
  public func history(of slot: Slot, in scope: Scope) throws -> [Assertion] {
    try assertions(in: scope, slot: slot, category: nil) { _ in true }
      .sorted { $0.validFrom > $1.validFrom }
  }

  /// Returns the evidence supporting `assertion`, in the order it was cited.
  public func evidence(supporting assertion: RecordID) throws -> [Evidence] {
    try database.read { transaction in
      guard let node = try locate(assertion, label: Labels.assertion, in: transaction) else {
        throw MemoryError.unknownRecord(assertion)
      }
      let stored = try readAssertion(node, in: transaction)
      return try stored.evidence.compactMap { id in
        try locate(id, label: Labels.evidence, in: transaction).map {
          try readEvidence($0, in: transaction)
        }
      }
    }
  }

  /// Returns the assertions derived from `evidence`, including superseded ones.
  ///
  /// This is the reverse of ``evidence(supporting:)``, and the query that says
  /// what would be affected by forgetting a record.
  public func assertions(derivedFrom evidence: RecordID) throws -> [Assertion] {
    try database.read { transaction in
      guard let node = try locate(evidence, label: Labels.evidence, in: transaction) else {
        throw MemoryError.unknownRecord(evidence)
      }
      let sources = try transaction.neighbors(
        of: node, outgoing: false, type: EdgeType(Edges.evidencedBy))
      return try sources.map { try readAssertion($0, in: transaction) }
    }
  }

  private func assertions(
    in scope: Scope, slot: Slot?, category: String?, where include: (Assertion) -> Bool
  ) throws -> [Assertion] {
    try database.read { transaction in
      let nodes =
        if let slot {
          try transaction.nodeIDs(
            label: Labels.assertion, property: Keys.slot, equals: .string(slot.rawValue))
        } else {
          try transaction.nodeIDs(label: Labels.assertion)
        }
      return
        try nodes
        .map { try readAssertion($0, in: transaction) }
        .filter { assertion in
          guard assertion.scope.isVisible(in: scope), include(assertion) else { return false }
          guard let category else { return true }
          return assertion.category == category
        }
        .sorted { ($0.slot.rawValue, $0.validFrom) < ($1.slot.rawValue, $1.validFrom) }
    }
  }

  // MARK: - Storage layout

  enum Labels {
    static let evidence = "Evidence"
    static let assertion = "Assertion"
  }

  enum Edges {
    /// From an assertion to the evidence that justifies it.
    static let evidencedBy = "EVIDENCED_BY"
    /// From a new assertion to the one it replaced.
    static let supersedes = "SUPERSEDES"
  }

  enum Keys {
    static let id = "id"
    static let kind = "kind"
    static let text = "text"
    static let scope = "scope"
    static let occurredAt = "occurredAt"
    static let recordedAt = "recordedAt"
    static let metadataKeys = "metadataKeys"
    static let metadataPrefix = "meta_"
    static let slot = "slot"
    static let value = "value"
    static let state = "state"
    static let validFrom = "validFrom"
    static let validTo = "validTo"
    static let quote = "quote"
    static let confidence = "confidence"
    static let category = "category"
    /// The property a record's embedding is stored under.
    static let embedding = "embedding"
  }

  /// Returns the node holding `id`, or `nil` when the store holds no such record.
  func locate(_ id: RecordID, label: String, in transaction: Transaction) throws -> NodeID? {
    try transaction.nodeIDs(
      label: label, property: Keys.id, equals: .string(id.rawValue), limit: 1
    ).first
  }

  func readEvidence(_ node: NodeID, in transaction: Transaction) throws -> Evidence {
    let id = RecordID(try string(Keys.id, node, in: transaction, fallback: ""))
    var metadata: [String: Value] = [:]
    let keys = try string(Keys.metadataKeys, node, in: transaction, fallback: "")
    for key in keys.split(separator: "\u{1F}").map(String.init) {
      metadata[key] = try transaction.propertyValue(Keys.metadataPrefix + key, ofNode: node)
    }
    return Evidence(
      id: id,
      kind: try string(Keys.kind, node, in: transaction, fallback: ""),
      text: try string(Keys.text, node, in: transaction, fallback: ""),
      scope: Scope(storageKey: try string(Keys.scope, node, in: transaction, fallback: "")),
      occurredAt: try date(Keys.occurredAt, node, in: transaction, id: id),
      recordedAt: try date(Keys.recordedAt, node, in: transaction, id: id),
      metadata: metadata)
  }

  func readAssertion(_ node: NodeID, in transaction: Transaction) throws -> Assertion {
    let id = RecordID(try string(Keys.id, node, in: transaction, fallback: ""))
    let rawState = try string(Keys.state, node, in: transaction, fallback: "")
    guard let state = AssertionState(rawValue: rawState) else {
      throw MemoryError.malformedRecord(id, "unknown state \"\(rawState)\"")
    }
    var validTo: Date?
    if case .integer(let milliseconds) = try transaction.propertyValue(Keys.validTo, ofNode: node) {
      validTo = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
    var confidence = 1.0
    if case .double(let stored) = try transaction.propertyValue(Keys.confidence, ofNode: node) {
      confidence = stored
    }
    let evidence = try transaction.neighbors(
      of: node, outgoing: true, type: EdgeType(Edges.evidencedBy)
    ).map { RecordID(try string(Keys.id, $0, in: transaction, fallback: "")) }
    let category = try transaction.propertyValue(Keys.category, ofNode: node)
    let quote = try transaction.propertyValue(Keys.quote, ofNode: node)
    return Assertion(
      id: id,
      slot: Slot(try string(Keys.slot, node, in: transaction, fallback: "")),
      value: try transaction.propertyValue(Keys.value, ofNode: node),
      text: try string(Keys.text, node, in: transaction, fallback: ""),
      scope: Scope(storageKey: try string(Keys.scope, node, in: transaction, fallback: "")),
      state: state,
      validFrom: try date(Keys.validFrom, node, in: transaction, id: id),
      validTo: validTo,
      evidence: evidence,
      quote: { if case .string(let text) = quote { return text } else { return nil } }(),
      confidence: confidence,
      category: { if case .string(let text) = category { return text } else { return nil } }())
  }

  private func string(
    _ key: String, _ node: NodeID, in transaction: Transaction, fallback: String
  ) throws -> String {
    guard case .string(let value) = try transaction.propertyValue(key, ofNode: node) else {
      return fallback
    }
    return value
  }

  private func date(
    _ key: String, _ node: NodeID, in transaction: Transaction, id: RecordID
  ) throws -> Date {
    guard case .integer(let milliseconds) = try transaction.propertyValue(key, ofNode: node) else {
      throw MemoryError.malformedRecord(id, "\(key) is missing or is not a timestamp")
    }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  }
}
