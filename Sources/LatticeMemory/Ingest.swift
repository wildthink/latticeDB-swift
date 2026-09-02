import Foundation
import LatticeDB

/// What one call to ``MemoryStore/record(_:)`` did.
///
/// Every outcome is reported, including the refusals. An extractor that proposes
/// nonsense produces a result with rejections rather than a thrown error, so a
/// caller can log the refusal, count it, or ignore it — but is never left
/// wondering why an assertion is missing.
public struct IngestResult: Sendable {
  /// The evidence as stored.
  public let evidence: Evidence

  /// The assertions written from it.
  public let asserted: [Assertion]

  /// The assertions these writes replaced, which remain readable as history.
  public let superseded: [RecordID]

  /// The proposals that were refused, with the reason for each.
  public let rejected: [Rejection]

  /// Whether anything was refused.
  public var hasRejections: Bool { !rejected.isEmpty }
}

extension MemoryStore {
  /// Stores `draft`, runs the extractors over it, and writes whatever survives
  /// validation.
  ///
  /// Everything happens in one transaction: the evidence, the assertions derived
  /// from it, and the supersession of whatever they replace either all commit or
  /// none do. There is no window in which evidence exists without its
  /// conclusions, or a conclusion without its evidence.
  ///
  /// Each proposal is checked before it is written. It must
  ///
  /// - name a slot the ``MemorySchema`` declares,
  /// - carry a value of the kind that slot's rule requires, and one of its
  ///   `allowedValues` when it lists any,
  /// - carry a quote when the rule requires one, and any quote it carries must
  ///   appear verbatim in the evidence text,
  /// - stay within the evidence's ``Scope``, which it may narrow but not leave,
  /// - and give a confidence between 0 and 1.
  ///
  /// A proposal failing any of these is returned in ``IngestResult/rejected``
  /// and nothing is written for it.
  ///
  /// - Throws: ``MemoryError/duplicateIdentifier(_:)`` when the draft supplies an
  ///   identifier the store already holds.
  @discardableResult
  public func record(_ draft: EvidenceDraft) throws -> IngestResult {
    let now = clock()
    let evidence = Evidence(
      id: draft.id ?? RecordID.generate(prefix: "ev", now: now),
      kind: draft.kind,
      text: draft.text,
      scope: draft.scope,
      occurredAt: draft.occurredAt ?? now,
      recordedAt: now,
      metadata: draft.metadata)

    var proposals: [AssertionProposal] = []
    var rejected: [Rejection] = []
    for extractor in extractors {
      do {
        proposals.append(contentsOf: try extractor.extract(from: evidence))
      } catch {
        rejected.append(
          Rejection(
            proposal: AssertionProposal(slot: "", value: .null),
            reason: .extractorFailed(String(describing: error))))
      }
    }


    return try database.write { transaction in
      if try locate(evidence.id, label: Labels.evidence, in: transaction) != nil {
        throw MemoryError.duplicateIdentifier(evidence.id)
      }
      let node = try write(evidence, in: transaction)
      var asserted: [Assertion] = []
      var superseded: [RecordID] = []
      for proposal in proposals {
        switch validate(proposal, against: evidence) {
        case .failure(let reason):
          rejected.append(Rejection(proposal: proposal, reason: reason))
        case .success(let checked):
          let outcome = try commit(
            checked, from: evidence, evidenceNode: node, now: now, in: transaction)
          if let assertion = outcome.assertion { asserted.append(assertion) }
          superseded.append(contentsOf: outcome.superseded)
        }
      }
      return IngestResult(
        evidence: evidence, asserted: asserted, superseded: superseded, rejected: rejected)
    }
  }

  /// Writes one assertion directly, bypassing the extractors.
  ///
  /// The proposal is validated exactly as an extractor's would be, so this is a
  /// shortcut past extraction, not past the schema. Use it when your caller
  /// already knows the value — an imported configuration, a form submission, a
  /// human correction — and only needs the evidence link and supersession.
  ///
  /// - Throws: ``MemoryError/unknownRecord(_:)`` when `evidence` is not in the
  ///   store, or ``Rejection`` when the proposal fails validation. Unlike
  ///   ``record(_:)``, a refusal here throws: the caller asked for this one
  ///   assertion, so it cannot be reported by omission.
  @discardableResult
  public func assert(_ proposal: AssertionProposal, from evidence: RecordID) throws -> Assertion {
    let now = clock()
    return try database.write { transaction in
      guard let node = try locate(evidence, label: Labels.evidence, in: transaction) else {
        throw MemoryError.unknownRecord(evidence)
      }
      let stored = try readEvidence(node, in: transaction)
      switch validate(proposal, against: stored) {
      case .failure(let reason):
        throw Rejection(proposal: proposal, reason: reason)
      case .success(let checked):
        let outcome = try commit(
          checked, from: stored, evidenceNode: node, now: now, in: transaction)
        guard let assertion = outcome.assertion else {
          throw Rejection(proposal: proposal, reason: .disallowedValue(proposal.text))
        }
        return assertion
      }
    }
  }

  /// Withdraws an assertion without replacing it.
  ///
  /// The assertion becomes ``AssertionState/retracted`` and its valid interval
  /// closes at `now`. Nothing is deleted: a retraction is a statement that this
  /// stopped being believed, and remains part of the record.
  public func retract(_ id: RecordID) throws {
    let now = clock()
    try database.write { transaction in
      guard let node = try locate(id, label: Labels.assertion, in: transaction) else {
        throw MemoryError.unknownRecord(id)
      }
      try transaction.setProperty(
        Keys.state, onNode: node, to: .string(AssertionState.retracted.rawValue))
      try transaction.setProperty(Keys.validTo, onNode: node, to: now.latticeValue)
    }
  }

  // MARK: - Validation

  /// A proposal that has passed validation, carrying the resolved values the
  /// proposal left implicit.
  struct CheckedProposal {
    var proposal: AssertionProposal
    var rule: SlotRule
    var scope: Scope
    var validFrom: Date
  }

  func validate(
    _ proposal: AssertionProposal, against evidence: Evidence
  ) -> Result<CheckedProposal, RejectionReason> {
    guard let rule = schema.rule(for: proposal.slot) else {
      return .failure(.undeclaredSlot(proposal.slot))
    }
    let kind = kindOf(proposal.value)
    guard kind == rule.kind else {
      return .failure(.wrongValueKind(expected: rule.kind, actual: kind))
    }
    if let allowed = rule.allowedValues {
      let text = AssertionProposal.describe(proposal.value)
      guard allowed.contains(text) else { return .failure(.disallowedValue(text)) }
    }
    if let quote = proposal.quote {
      guard evidence.text.contains(quote) else { return .failure(.unfaithfulQuote(quote)) }
    } else if rule.requiresQuote {
      return .failure(.missingQuote)
    }
    guard (0...1).contains(proposal.confidence) else {
      return .failure(.invalidConfidence(proposal.confidence))
    }
    let scope = proposal.scope ?? evidence.scope
    guard scope.contains(evidence.scope) else {
      return .failure(.scopeEscapesEvidence(proposed: scope, evidence: evidence.scope))
    }
    return .success(
      CheckedProposal(
        proposal: proposal, rule: rule, scope: scope,
        validFrom: proposal.validFrom ?? evidence.occurredAt))
  }

  /// The scalar kind of a stored value.
  ///
  /// `LatticeDB` derives this internally when validating a graph schema but does
  /// not expose the conversion, so slot validation computes it here.
  private func kindOf(_ value: Value) -> ValueKind {
    switch value {
    case .null: return .null
    case .bool: return .bool
    case .integer: return .integer
    case .double: return .double
    case .string: return .string
    }
  }

  // MARK: - Writing

  private struct CommitOutcome {
    var assertion: Assertion?
    var superseded: [RecordID]
  }

  private func commit(
    _ checked: CheckedProposal, from evidence: Evidence, evidenceNode: NodeID, now: Date,
    in transaction: Transaction
  ) throws -> CommitOutcome {
    let existing = try currentNodes(
      slot: checked.proposal.slot, scope: checked.scope, in: transaction)

    // Re-asserting a value that is already current is not news, whatever the
    // cardinality. Writing nothing is what keeps a replayed source from
    // accumulating duplicates, and from closing an interval against itself.
    for node in existing {
      let value = try transaction.propertyValue(Keys.value, ofNode: node)
      if value == checked.proposal.value { return CommitOutcome(assertion: nil, superseded: []) }
    }

    var superseded: [RecordID] = []
    if checked.rule.cardinality == .single {
      // A single-valued slot holds one current answer, so every other current
      // assertion for it closes at the moment this one becomes true.
      for node in existing {
        superseded.append(try close(node, at: checked.validFrom, in: transaction))
      }
    }

    let assertion = Assertion(
      id: RecordID.generate(prefix: "as", now: now),
      slot: checked.proposal.slot,
      value: checked.proposal.value,
      text: checked.proposal.text,
      scope: checked.scope,
      state: .current,
      validFrom: checked.validFrom,
      validTo: nil,
      evidence: [evidence.id],
      quote: checked.proposal.quote,
      confidence: checked.proposal.confidence,
      category: checked.rule.category)

    let node = try write(assertion, in: transaction)
    _ = try transaction.createEdge(from: node, to: evidenceNode, type: Edges.evidencedBy)
    for replaced in superseded {
      if let old = try locate(replaced, label: Labels.assertion, in: transaction) {
        _ = try transaction.createEdge(from: node, to: old, type: Edges.supersedes)
      }
    }
    return CommitOutcome(assertion: assertion, superseded: superseded)
  }

  /// Returns the nodes currently asserting `slot` in exactly `scope`.
  ///
  /// Supersession matches the stored scope exactly rather than by visibility: a
  /// value set for one project must not silently replace the value another
  /// project set for the same slot.
  private func currentNodes(
    slot: Slot, scope: Scope, in transaction: Transaction
  ) throws -> [NodeID] {
    let key = scope.storageKey
    let candidates = try transaction.nodeIDs(
      label: Labels.assertion, property: Keys.slot, equals: .string(slot.rawValue))
    var matches: [NodeID] = []
    for node in candidates {
      let state = try transaction.propertyValue(Keys.state, ofNode: node)
      guard state == .string(AssertionState.current.rawValue) else { continue }
      guard try transaction.propertyValue(Keys.scope, ofNode: node) == .string(key) else {
        continue
      }
      matches.append(node)
    }
    return matches
  }

  private func close(_ node: NodeID, at date: Date, in transaction: Transaction) throws -> RecordID
  {
    try transaction.setProperty(
      Keys.state, onNode: node, to: .string(AssertionState.superseded.rawValue))
    try transaction.setProperty(Keys.validTo, onNode: node, to: date.latticeValue)
    guard case .string(let id) = try transaction.propertyValue(Keys.id, ofNode: node) else {
      throw MemoryError.malformedRecord(RecordID(""), "assertion node \(node) has no id")
    }
    return RecordID(id)
  }

  private func write(_ evidence: Evidence, in transaction: Transaction) throws -> NodeID {
    let node = try transaction.createNode(label: Labels.evidence)
    try transaction.setProperty(Keys.id, onNode: node, to: .string(evidence.id.rawValue))
    try transaction.setProperty(Keys.kind, onNode: node, to: .string(evidence.kind))
    try transaction.setProperty(Keys.text, onNode: node, to: .string(evidence.text))
    try transaction.setProperty(Keys.scope, onNode: node, to: .string(evidence.scope.storageKey))
    try transaction.setProperty(
      Keys.occurredAt, onNode: node, to: evidence.occurredAt.latticeValue)
    try transaction.setProperty(
      Keys.recordedAt, onNode: node, to: evidence.recordedAt.latticeValue)
    // Metadata keys are recorded together so the dictionary can be read back
    // without scanning for properties by prefix, which the native API cannot do.
    let keys = evidence.metadata.keys.sorted()
    try transaction.setProperty(
      Keys.metadataKeys, onNode: node, to: .string(keys.joined(separator: "\u{1F}")))
    for key in keys {
      try transaction.setProperty(
        Keys.metadataPrefix + key, onNode: node, to: evidence.metadata[key] ?? .null)
    }
    return node
  }

  private func write(_ assertion: Assertion, in transaction: Transaction) throws -> NodeID {
    let node = try transaction.createNode(label: Labels.assertion)
    try transaction.setProperty(Keys.id, onNode: node, to: .string(assertion.id.rawValue))
    try transaction.setProperty(Keys.slot, onNode: node, to: .string(assertion.slot.rawValue))
    try transaction.setProperty(Keys.value, onNode: node, to: assertion.value)
    try transaction.setProperty(Keys.text, onNode: node, to: .string(assertion.text))
    try transaction.setProperty(Keys.scope, onNode: node, to: .string(assertion.scope.storageKey))
    try transaction.setProperty(Keys.state, onNode: node, to: .string(assertion.state.rawValue))
    try transaction.setProperty(
      Keys.validFrom, onNode: node, to: assertion.validFrom.latticeValue)
    try transaction.setProperty(
      Keys.validTo, onNode: node, to: assertion.validTo?.latticeValue ?? .null)
    try transaction.setProperty(
      Keys.quote, onNode: node, to: assertion.quote.map { .string($0) } ?? .null)
    try transaction.setProperty(
      Keys.confidence, onNode: node, to: .double(assertion.confidence))
    try transaction.setProperty(
      Keys.category, onNode: node, to: assertion.category.map { .string($0) } ?? .null)
    return node
  }
}
