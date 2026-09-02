import Foundation
import LatticeDB

// MARK: - Request

/// How thoroughly to forget.
public enum ForgetMode: String, Sendable {
  /// Keep the record's identifier, kind, and timestamps; discard its text,
  /// metadata, and vector.
  ///
  /// A reference to a tombstone resolves to "this was forgotten" rather than to
  /// nothing, so an audit can show that a deletion happened and when. This is
  /// the default, and the right choice unless something obliges you to leave no
  /// trace.
  case tombstone

  /// Delete the record outright, leaving nothing behind — not even the fact that
  /// it existed.
  ///
  /// Use this when a tombstone is itself too much, such as an erasure request
  /// you must be able to certify. Afterwards ``MemoryStore/evidence(_:)`` returns
  /// `nil` for the identifier, exactly as it would for one never stored.
  case erase
}

/// Which records to forget, and how.
///
/// A request must name something. One with no identifiers and no filters is
/// refused with ``ForgetError/unconstrained``, because "forget everything" is
/// too easy to write by accident and too hard to undo.
public struct ForgetRequest: Sendable {
  /// Evidence to forget by identifier.
  public var identifiers: [RecordID]

  /// Forget evidence whose text matches this full-text query.
  public var query: String?

  /// Forget evidence in exactly this scope.
  ///
  /// This matches the stored scope exactly rather than by visibility. Forgetting
  /// is destructive, so a broad scope must not reach records that merely happen
  /// to be visible from it.
  public var scope: Scope?

  /// Forget only these evidence kinds.
  public var evidenceKinds: Set<String>?

  /// Forget only evidence that occurred in this window.
  public var occurredIn: Range<Date>?

  /// How thoroughly to forget.
  public var mode: ForgetMode

  /// The most records one request may forget.
  ///
  /// A cap turns an over-broad filter into a truncated report rather than a
  /// cleared store. ``ForgetReport/wasTruncated`` says when it was reached.
  public var limit: Int

  public init(
    identifiers: [RecordID] = [], query: String? = nil, scope: Scope? = nil,
    evidenceKinds: Set<String>? = nil, occurredIn: Range<Date>? = nil,
    mode: ForgetMode = .tombstone, limit: Int = 1_000
  ) {
    self.identifiers = identifiers
    self.query = query
    self.scope = scope
    self.evidenceKinds = evidenceKinds
    self.occurredIn = occurredIn
    self.mode = mode
    self.limit = limit
  }

  /// Forgets specific records.
  public static func identifiers(
    _ identifiers: [RecordID], mode: ForgetMode = .tombstone
  ) -> ForgetRequest {
    ForgetRequest(identifiers: identifiers, mode: mode)
  }

  /// Forgets everything matching a set of filters.
  public static func matching(
    query: String? = nil, scope: Scope? = nil, kinds: Set<String>? = nil,
    occurredIn: Range<Date>? = nil, mode: ForgetMode = .tombstone, limit: Int = 1_000
  ) -> ForgetRequest {
    ForgetRequest(
      query: query, scope: scope, evidenceKinds: kinds, occurredIn: occurredIn, mode: mode,
      limit: limit)
  }

  var isConstrained: Bool {
    !identifiers.isEmpty || query != nil || scope != nil || evidenceKinds != nil
      || occurredIn != nil
  }
}

/// A failure raised before anything is forgotten.
public enum ForgetError: Error, Sendable, Equatable {
  /// The request named neither identifiers nor any filter, so it would have
  /// matched the whole store.
  case unconstrained
}

// MARK: - Report

/// An assertion that lost some of its support but not all of it.
public struct WeakenedAssertion: Sendable, Equatable {
  /// The assertion.
  public let id: RecordID

  /// The citations it lost.
  public let removedEvidence: [RecordID]

  /// The citations it keeps, which are why it survives.
  public let remainingEvidence: [RecordID]

  /// Whether its quote was dropped because the text it quoted is gone.
  public let lostQuote: Bool
}

/// What forgetting did, or would do.
///
/// The same type is returned by ``MemoryStore/forget(_:)`` and
/// ``MemoryStore/forgetPreview(_:)``; ``wasApplied`` distinguishes them. Run the
/// preview first when the request uses filters — the closure can reach further
/// than it looks.
public struct ForgetReport: Sendable, Equatable {
  /// The evidence forgotten, or that would be.
  public let evidence: [RecordID]

  /// Assertions that lost every citation and were therefore retracted and
  /// redacted.
  public let retractedAssertions: [RecordID]

  /// Assertions that lost some citations and survived on the rest.
  public let weakenedAssertions: [WeakenedAssertion]

  /// The mode the request asked for.
  public let mode: ForgetMode

  /// Whether this was written, or only computed.
  public let wasApplied: Bool

  /// Whether ``ForgetRequest/limit`` cut the selection short.
  public let wasTruncated: Bool

  /// Whether anything was selected at all.
  public var isEmpty: Bool { evidence.isEmpty }
}

// MARK: - Pipeline

extension MemoryStore {
  /// Reports what ``forget(_:)`` would do, without changing anything.
  ///
  /// Worth running whenever the request selects by filter rather than by
  /// identifier: forgetting propagates, so a request that names three records
  /// may retract a dozen assertions.
  public func forgetPreview(_ request: ForgetRequest) throws -> ForgetReport {
    guard request.isConstrained else { throw ForgetError.unconstrained }
    return try database.read { transaction in
      try plan(request, applied: false, in: transaction)
    }
  }

  /// Forgets the selected evidence and everything derived from it.
  ///
  /// Propagation is the point. Discarding a record while the conclusions drawn
  /// from it stay readable does not forget anything, so:
  ///
  /// - An assertion whose citations are **all** forgotten is retracted, and — in
  ///   ``ForgetMode/tombstone`` — has its value, text, and quote redacted too.
  ///   A quote is a verbatim copy of the forgotten text; leaving it would be the
  ///   whole leak.
  /// - An assertion with **surviving** citations stands, minus the forgotten
  ///   ones. It loses its quote only when the text it quoted is among them.
  ///
  /// Supersession is not undone. That a value was replaced remains true whatever
  /// happens to the evidence for the replacement, so a superseded assertion is
  /// never resurrected by forgetting the one that displaced it.
  ///
  /// Everything happens in one transaction.
  ///
  /// - Throws: ``ForgetError/unconstrained`` when the request names nothing.
  @discardableResult
  public func forget(_ request: ForgetRequest) throws -> ForgetReport {
    guard request.isConstrained else { throw ForgetError.unconstrained }
    let now = clock()
    return try database.write { transaction in
      let report = try plan(request, applied: true, in: transaction)

      for weakened in report.weakenedAssertions {
        guard let node = try locate(weakened.id, label: Labels.assertion, in: transaction) else {
          continue
        }
        if weakened.lostQuote {
          try transaction.setProperty(Keys.quote, onNode: node, to: .null)
        }
        // In tombstone mode the evidence node survives, so the citation edge has
        // to be cut explicitly. Erasing the node takes its edges with it.
        if request.mode == .tombstone {
          for evidence in weakened.removedEvidence {
            if let target = try locate(evidence, label: Labels.evidence, in: transaction) {
              try transaction.deleteEdge(from: node, to: target, type: Edges.evidencedBy)
            }
          }
        }
      }

      for id in report.retractedAssertions {
        guard let node = try locate(id, label: Labels.assertion, in: transaction) else { continue }
        try transaction.setProperty(
          Keys.state, onNode: node, to: .string(AssertionState.retracted.rawValue))
        try transaction.setProperty(Keys.validTo, onNode: node, to: now.latticeValue)
        if request.mode == .tombstone {
          try redactAssertion(node, in: transaction)
        } else {
          try transaction.deleteNode(node)
        }
      }

      for id in report.evidence {
        guard let node = try locate(id, label: Labels.evidence, in: transaction) else { continue }
        if request.mode == .tombstone {
          try redactEvidence(node, at: now, in: transaction)
        } else {
          try transaction.deleteNode(node)
        }
      }

      return report
    }
  }

  // MARK: - Closure

  private func plan(
    _ request: ForgetRequest, applied: Bool, in transaction: Transaction
  ) throws -> ForgetReport {
    let (targets, wasTruncated) = try select(request, in: transaction)
    let selected = Set(targets)

    var retracted: [RecordID] = []
    var weakened: [WeakenedAssertion] = []
    var seen: Set<RecordID> = []

    for id in targets {
      guard let node = try locate(id, label: Labels.evidence, in: transaction) else { continue }
      let dependents = try transaction.neighbors(
        of: node, outgoing: false, type: EdgeType(Edges.evidencedBy))
      for dependent in dependents {
        let assertion = try readAssertion(dependent, in: transaction)
        guard seen.insert(assertion.id).inserted else { continue }
        let removed = assertion.evidence.filter { selected.contains($0) }
        let remaining = assertion.evidence.filter { !selected.contains($0) }
        if remaining.isEmpty {
          retracted.append(assertion.id)
        } else {
          weakened.append(
            WeakenedAssertion(
              id: assertion.id, removedEvidence: removed, remainingEvidence: remaining,
              lostQuote: try quoteIsLost(assertion, remaining: remaining, in: transaction)))
        }
      }
    }

    return ForgetReport(
      evidence: targets, retractedAssertions: retracted, weakenedAssertions: weakened,
      mode: request.mode, wasApplied: applied, wasTruncated: wasTruncated)
  }

  /// Whether an assertion's quote can still be found in evidence that survives.
  ///
  /// A quote is verbatim text lifted from evidence. Once the record it came from
  /// is gone, keeping the quote would keep the very words the request asked to
  /// forget — unless some other surviving citation happens to contain them.
  private func quoteIsLost(
    _ assertion: Assertion, remaining: [RecordID], in transaction: Transaction
  ) throws -> Bool {
    guard let quote = assertion.quote else { return false }
    for id in remaining {
      guard let node = try locate(id, label: Labels.evidence, in: transaction) else { continue }
      if try readEvidence(node, in: transaction).text.contains(quote) { return false }
    }
    return true
  }

  /// Finds the evidence a request selects.
  ///
  /// Scope matches the stored scope exactly rather than by visibility:
  /// forgetting is destructive, and a broad context must not reach records that
  /// merely happen to be visible from it. Tombstones are skipped, since one has
  /// nothing left to remove and counting it again would double-report a closure.
  private func select(
    _ request: ForgetRequest, in transaction: Transaction
  ) throws -> (targets: [RecordID], wasTruncated: Bool) {
    var nodes: [NodeID] = []
    if !request.identifiers.isEmpty {
      nodes = try request.identifiers.compactMap {
        try locate($0, label: Labels.evidence, in: transaction)
      }
    } else if let query = request.query {
      nodes = try transaction.fullTextSearch(
        query, label: Labels.evidence, property: Keys.text, limit: request.limit + 1
      ).map(\.node)
    } else {
      nodes = try transaction.nodeIDs(label: Labels.evidence)
    }

    var targets: [RecordID] = []
    for node in nodes {
      let evidence = try readEvidence(node, in: transaction)
      if evidence.isForgotten { continue }
      if let scope = request.scope, evidence.scope != scope { continue }
      if let kinds = request.evidenceKinds, !kinds.contains(evidence.kind) { continue }
      if let window = request.occurredIn, !window.contains(evidence.occurredAt) { continue }
      targets.append(evidence.id)
      if targets.count > request.limit {
        return (Array(targets.prefix(request.limit)), true)
      }
    }
    return (targets, false)
  }

  // MARK: - Redaction

  private func redactEvidence(_ node: NodeID, at now: Date, in transaction: Transaction) throws {
    let evidence = try readEvidence(node, in: transaction)
    try transaction.setProperty(Keys.text, onNode: node, to: .string(""))
    for key in evidence.metadata.keys {
      try transaction.setProperty(Keys.metadataPrefix + key, onNode: node, to: .null)
    }
    try transaction.setProperty(Keys.metadataKeys, onNode: node, to: .string(""))
    try transaction.setProperty(Keys.forgotten, onNode: node, to: .bool(true))
    try transaction.setProperty(Keys.forgottenAt, onNode: node, to: now.latticeValue)
    try clearVector(node, in: transaction)
  }

  private func redactAssertion(_ node: NodeID, in transaction: Transaction) throws {
    try transaction.setProperty(Keys.text, onNode: node, to: .string(""))
    try transaction.setProperty(Keys.quote, onNode: node, to: .null)
    try transaction.setProperty(Keys.value, onNode: node, to: .null)
    try clearVector(node, in: transaction)
  }

  /// Overwrites a record's embedding with zeroes.
  ///
  /// The native API has no vector removal, and an embedding of forgotten text
  /// still answers a nearest-neighbor search for it. A zero vector is inert:
  /// retrieval filters the record out on its state before the distance matters.
  private func clearVector(_ node: NodeID, in transaction: Transaction) throws {
    guard let embedder else { return }
    try transaction.setVector(
      [Float](repeating: 0, count: Int(embedder.dimensions)), forKey: Keys.embedding,
      onNode: node)
  }
}
