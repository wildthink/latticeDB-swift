import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private let secret: Slot = "user.secret"
private let manager: Slot = "package.manager"

private var forgetSchema: MemorySchema {
  [
    secret: SlotRule(kind: .string, category: "personal"),
    manager: SlotRule(kind: .string, category: "tooling"),
  ]
}

private func withStore<T>(
  embedder: (any TextEmbedder)? = nil, _ body: (MemoryStore) throws -> T
) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("forget-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(try MemoryStore(path: path, schema: forgetSchema, embedder: embedder))
}

private func at(_ day: Int) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
}

// MARK: - Safety

@Test func anUnconstrainedRequestIsRefused() throws {
  try withStore { store in
    #expect(throws: ForgetError.unconstrained) { try store.forget(ForgetRequest()) }
    #expect(throws: ForgetError.unconstrained) { try store.forgetPreview(ForgetRequest()) }
  }
}

@Test func aPreviewChangesNothing() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "a secret")).evidence
    try store.assert(
      AssertionProposal(slot: secret, value: .string("s"), quote: "a secret"), from: evidence.id)

    let preview = try store.forgetPreview(.identifiers([evidence.id]))
    #expect(!preview.wasApplied)
    #expect(preview.evidence == [evidence.id])
    #expect(preview.retractedAssertions.count == 1)

    let stored = try #require(try store.evidence(evidence.id))
    #expect(stored.text == "a secret")
    #expect(!stored.isForgotten)
    #expect(try store.currentAssertions(in: .global).count == 1)
  }
}

@Test func theLimitTruncatesRatherThanClearingTheStore() throws {
  try withStore { store in
    for day in 1...5 { try store.record(EvidenceDraft(text: "note \(day)", occurredAt: at(day))) }

    let report = try store.forget(.matching(kinds: ["message"], limit: 2))
    #expect(report.evidence.count == 2)
    #expect(report.wasTruncated)

    let remaining = try store.retrieve(RetrievalRequest(kinds: .evidence, mode: .recency))
    #expect(remaining.items.count == 3)
  }
}

// MARK: - Tombstones

@Test func aTombstoneKeepsIdentityAndLosesContent() throws {
  try withStore { store in
    let evidence = try store.record(
      EvidenceDraft(
        kind: "note", text: "my home address", occurredAt: at(1),
        metadata: ["author": .string("sam")])
    ).evidence

    try store.forget(.identifiers([evidence.id]))

    let stored = try #require(try store.evidence(evidence.id))
    #expect(stored.isForgotten)
    #expect(stored.text.isEmpty)
    #expect(stored.metadata.isEmpty)
    // Identity and timing survive, so an audit can show a deletion happened.
    #expect(stored.id == evidence.id)
    #expect(stored.kind == "note")
    #expect(stored.occurredAt == at(1))
  }
}

@Test func erasingLeavesNothingBehind() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "my home address")).evidence
    let assertion = try store.assert(
      AssertionProposal(slot: secret, value: .string("s")), from: evidence.id)

    try store.forget(.identifiers([evidence.id], mode: .erase))

    #expect(try store.evidence(evidence.id) == nil)
    #expect(try store.assertion(assertion.id) == nil)
  }
}

@Test func forgottenEvidenceIsNotEvenALexicalCandidate() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "distinctive marmalade")).evidence
    try store.forget(.identifiers([evidence.id]))

    // Redaction clears the indexed text, so the tombstone never reaches the
    // filter that would have dropped it.
    let result = try store.retrieve(
      RetrievalRequest(query: "marmalade", kinds: .evidence, mode: .lexical))
    #expect(result.items.isEmpty)
    #expect(result.trace.candidates == 0)
  }
}

@Test func forgottenEvidenceIsFilteredOutWhenItIsACandidate() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "distinctive marmalade")).evidence
    try store.record(EvidenceDraft(text: "a surviving note"))
    try store.forget(.identifiers([evidence.id]))

    // Recency enumerates nodes rather than searching text, so the tombstone is a
    // candidate here and the filter is what excludes it.
    let result = try store.retrieve(RetrievalRequest(kinds: .evidence, mode: .recency))
    #expect(result.items.map(\.text) == ["a surviving note"])
    #expect(result.trace.dropped[.forgotten] == 1)
  }
}

@Test func forgottenEvidenceStillAppearsInDirectProvenance() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "supporting text")).evidence
    let assertion = try store.assert(
      AssertionProposal(slot: manager, value: .string("pnpm")), from: evidence.id)
    try store.forget(.identifiers([evidence.id]))

    // A redacted citation must stay distinguishable from one that never existed.
    let support = try store.evidence(supporting: assertion.id)
    #expect(support.map(\.id) == [evidence.id])
    #expect(support[0].isForgotten)
  }
}

// MARK: - Propagation

@Test func anAssertionLosingAllSupportIsRetractedAndRedacted() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "my password is hunter2")).evidence
    let assertion = try store.assert(
      AssertionProposal(
        slot: secret, value: .string("hunter2"), text: "password is hunter2",
        quote: "my password is hunter2"),
      from: evidence.id)

    let report = try store.forget(.identifiers([evidence.id]))
    #expect(report.retractedAssertions == [assertion.id])

    let stored = try #require(try store.assertion(assertion.id))
    #expect(stored.state == .retracted)
    // The derived text and the quote are verbatim copies of the forgotten text.
    // Leaving either would be the whole leak.
    #expect(stored.text.isEmpty)
    #expect(stored.quote == nil)
    #expect(stored.value == .null)
    #expect(try store.currentAssertions(in: .global).isEmpty)
  }
}

@Test func redactedAssertionsAreGoneFromHistoricalReadsToo() throws {
  try withStore { store in
    let evidence = try store.record(
      EvidenceDraft(text: "my password is hunter2", occurredAt: at(1))
    ).evidence
    try store.assert(
      AssertionProposal(slot: secret, value: .string("hunter2")), from: evidence.id)

    try store.forget(.identifiers([evidence.id]))

    #expect(try store.assertions(validAt: at(5), in: .global).isEmpty)
    let retrieved = try store.retrieve(
      RetrievalRequest(kinds: .assertions, validAt: at(5), mode: .recency))
    #expect(retrieved.items.isEmpty)
  }
}

@Test func anAssertionWithSurvivingSupportStandsWithoutIt() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "we adopted pnpm in March")).evidence
    let second = try store.record(EvidenceDraft(text: "confirming: pnpm")).evidence

    let assertion = try store.assert(
      AssertionProposal(slot: manager, value: .string("pnpm"), text: "manager = pnpm"),
      from: first.id)
    // Cite the second record for the same assertion.
    try store.database.write { transaction in
      let assertionNode = try #require(
        try store.locate(assertion.id, label: MemoryStore.Labels.assertion, in: transaction))
      let evidenceNode = try #require(
        try store.locate(second.id, label: MemoryStore.Labels.evidence, in: transaction))
      _ = try transaction.createEdge(
        from: assertionNode, to: evidenceNode, type: MemoryStore.Edges.evidencedBy)
    }

    let report = try store.forget(.identifiers([first.id]))
    #expect(report.retractedAssertions.isEmpty)
    #expect(report.weakenedAssertions.count == 1)
    #expect(report.weakenedAssertions[0].removedEvidence == [first.id])
    #expect(report.weakenedAssertions[0].remainingEvidence == [second.id])

    let stored = try #require(try store.assertion(assertion.id))
    #expect(stored.state == .current)
    #expect(stored.evidence == [second.id])
    #expect(stored.text == "manager = pnpm")
  }
}

@Test func aQuoteIsDroppedOnlyWhenTheTextItQuotedIsGone() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "we adopted pnpm in March")).evidence
    let second = try store.record(EvidenceDraft(text: "we adopted pnpm again")).evidence

    let assertion = try store.assert(
      AssertionProposal(slot: manager, value: .string("pnpm"), quote: "adopted pnpm"),
      from: first.id)
    try store.database.write { transaction in
      let assertionNode = try #require(
        try store.locate(assertion.id, label: MemoryStore.Labels.assertion, in: transaction))
      let evidenceNode = try #require(
        try store.locate(second.id, label: MemoryStore.Labels.evidence, in: transaction))
      _ = try transaction.createEdge(
        from: assertionNode, to: evidenceNode, type: MemoryStore.Edges.evidencedBy)
    }

    // The surviving record contains the same words, so the citation still checks out.
    let report = try store.forget(.identifiers([first.id]))
    #expect(!report.weakenedAssertions[0].lostQuote)
    #expect(try store.assertion(assertion.id)?.quote == "adopted pnpm")
  }
}

@Test func aQuoteFoundNowhereElseIsDropped() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "the passphrase is opensesame")).evidence
    let second = try store.record(EvidenceDraft(text: "unrelated note")).evidence

    let assertion = try store.assert(
      AssertionProposal(
        slot: secret, value: .string("opensesame"), quote: "passphrase is opensesame"),
      from: first.id)
    try store.database.write { transaction in
      let assertionNode = try #require(
        try store.locate(assertion.id, label: MemoryStore.Labels.assertion, in: transaction))
      let evidenceNode = try #require(
        try store.locate(second.id, label: MemoryStore.Labels.evidence, in: transaction))
      _ = try transaction.createEdge(
        from: assertionNode, to: evidenceNode, type: MemoryStore.Edges.evidencedBy)
    }

    let report = try store.forget(.identifiers([first.id]))
    #expect(report.weakenedAssertions[0].lostQuote)
    #expect(try store.assertion(assertion.id)?.quote == nil)
  }
}

@Test func supersessionIsNotUndoneByForgetting() throws {
  try withStore { store in
    let old = try store.record(EvidenceDraft(text: "we use npm", occurredAt: at(1))).evidence
    try store.assert(AssertionProposal(slot: manager, value: .string("npm")), from: old.id)
    let new = try store.record(EvidenceDraft(text: "we use pnpm", occurredAt: at(3))).evidence
    try store.assert(AssertionProposal(slot: manager, value: .string("pnpm")), from: new.id)

    // Forgetting the newer evidence retracts the newer assertion. The older one
    // does not come back: that it was replaced remains true.
    try store.forget(.identifiers([new.id]))

    #expect(try store.currentAssertions(in: .global).isEmpty)
    let history = try store.history(of: manager, in: .global)
    #expect(history.map(\.state) == [.retracted, .superseded])
  }
}

// MARK: - Selectors

@Test func forgettingBySearchMatchesEvidenceText() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "distinctive marmalade recipe"))
    try store.record(EvidenceDraft(text: "an unrelated note"))

    let report = try store.forget(.matching(query: "marmalade"))
    #expect(report.evidence.count == 1)

    let remaining = try store.retrieve(RetrievalRequest(kinds: .evidence, mode: .recency))
    #expect(remaining.items.map(\.text) == ["an unrelated note"])
  }
}

@Test func forgettingByScopeMatchesExactlyNotByVisibility() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "broad", scope: ["project": "a"]))
    try store.record(EvidenceDraft(text: "narrow", scope: ["project": "a", "user": "sam"]))

    // ["project": "a"] can *see* the narrower record, but forgetting must not
    // reach it — destruction does not follow visibility.
    let report = try store.forget(.matching(scope: ["project": "a"]))
    #expect(report.evidence.count == 1)

    let remaining = try store.retrieve(
      RetrievalRequest(scope: ["project": "a", "user": "sam"], kinds: .evidence, mode: .recency))
    #expect(remaining.items.map(\.text) == ["narrow"])
  }
}

@Test func forgettingByKindAndWindowNarrowsTheSelection() throws {
  try withStore { store in
    try store.record(EvidenceDraft(kind: "commit", text: "a commit", occurredAt: at(1)))
    try store.record(EvidenceDraft(kind: "message", text: "a message", occurredAt: at(2)))
    try store.record(EvidenceDraft(kind: "commit", text: "a later commit", occurredAt: at(9)))

    let report = try store.forget(
      .matching(kinds: ["commit"], occurredIn: at(0)..<at(5)))
    #expect(report.evidence.count == 1)

    let remaining = try store.retrieve(RetrievalRequest(kinds: .evidence, mode: .recency))
    #expect(Set(remaining.items.map(\.text)) == ["a message", "a later commit"])
  }
}

@Test func forgettingATombstoneAgainIsANoOp() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "once")).evidence
    try store.forget(.identifiers([evidence.id]))

    let again = try store.forget(.identifiers([evidence.id]))
    #expect(again.isEmpty)
    #expect(again.retractedAssertions.isEmpty)
  }
}

@Test func forgettingAnUnknownIdentifierSelectsNothing() throws {
  try withStore { store in
    let report = try store.forget(.identifiers([RecordID("nope")]))
    #expect(report.isEmpty)
  }
}

// MARK: - Vectors

@Test func forgettingClearsTheStoredEmbedding() throws {
  try withStore(embedder: HashEmbedder(dimensions: 64)) { store in
    let evidence = try store.record(EvidenceDraft(text: "distinctive marmalade")).evidence
    try store.forget(.identifiers([evidence.id]))

    let result = try store.retrieve(
      RetrievalRequest(query: "distinctive marmalade", kinds: .evidence, mode: .vector))
    #expect(result.items.isEmpty)
  }
}
