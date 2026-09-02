import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private let digest: Slot = "week.digest"
private let manager: Slot = "package.manager"

private var consolidationSchema: MemorySchema {
  [
    digest: SlotRule(kind: .string, category: "summaries"),
    manager: SlotRule(kind: .string, category: "tooling"),
  ]
}

private func withStore<T>(_ body: (MemoryStore) throws -> T) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("consolidate-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(try MemoryStore(path: path, schema: consolidationSchema))
}

private func at(_ day: Int) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
}

// MARK: - Multi-evidence assertions

@Test func anAssertionCanCiteSeveralRecords() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "we adopted pnpm", occurredAt: at(1))).evidence
    let second = try store.record(EvidenceDraft(text: "pnpm confirmed", occurredAt: at(3))).evidence

    let assertion = try store.assert(
      AssertionProposal(slot: manager, value: .string("pnpm")), from: [first.id, second.id])

    #expect(assertion.evidence == [first.id, second.id])
    // A conclusion is not true until the last record supporting it exists.
    #expect(assertion.validFrom == at(3))
    #expect(try store.evidence(supporting: assertion.id).map(\.id) == [first.id, second.id])
  }
}

@Test func aQuoteNeedAppearInOnlyOneCitedRecord() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "the passphrase is opensesame")).evidence
    let second = try store.record(EvidenceDraft(text: "an unrelated note")).evidence

    let assertion = try store.assert(
      AssertionProposal(slot: manager, value: .string("pnpm"), quote: "passphrase is opensesame"),
      from: [first.id, second.id])
    #expect(assertion.quote == "passphrase is opensesame")

    #expect(throws: Rejection.self) {
      try store.assert(
        AssertionProposal(slot: manager, value: .string("npm"), quote: "in neither record"),
        from: [first.id, second.id])
    }
  }
}

@Test func aConclusionIsAsNarrowAsItsNarrowestSource() throws {
  try withStore { store in
    let narrow = try store.record(
      EvidenceDraft(text: "one", scope: ["project": "a", "user": "sam"])
    ).evidence
    let broad = try store.record(EvidenceDraft(text: "two", scope: ["project": "a"])).evidence

    // Merging must narrow, never widen: a conclusion drawn partly from sam's
    // record must not answer a query that never named sam.
    let assertion = try store.assert(
      AssertionProposal(slot: manager, value: .string("pnpm")), from: [narrow.id, broad.id])
    #expect(assertion.scope == ["project": "a", "user": "sam"])
    #expect(try store.currentAssertions(in: ["project": "a"]).isEmpty)
    #expect(try store.currentAssertions(in: ["project": "a", "user": "sam"]).count == 1)
  }
}

@Test func sourcesThatDisagreeOnAScopeCannotBeCombined() throws {
  try withStore { store in
    let a = try store.record(EvidenceDraft(text: "one", scope: ["project": "a"])).evidence
    let b = try store.record(EvidenceDraft(text: "two", scope: ["project": "b"])).evidence

    // There is no scope containing both, so writing anywhere would be wrong.
    #expect(throws: Rejection.self) {
      try store.assert(
        AssertionProposal(slot: manager, value: .string("pnpm")), from: [a.id, b.id])
    }
  }
}

@Test func citingAnUnknownRecordIsRefused() throws {
  try withStore { store in
    let known = try store.record(EvidenceDraft(text: "one")).evidence
    #expect(throws: MemoryError.unknownRecord(RecordID("nope"))) {
      try store.assert(
        AssertionProposal(slot: manager, value: .string("pnpm")),
        from: [known.id, RecordID("nope")])
    }
  }
}

// MARK: - Consolidation

@Test func consolidationWritesOneAssertionCitingEverythingItRead() throws {
  try withStore { store in
    for day in 1...3 {
      try store.record(EvidenceDraft(kind: "log", text: "entry \(day)", occurredAt: at(day)))
    }

    let result = try store.consolidate(
      .matching(kinds: ["log"]), using: DigestConsolidator(slot: digest))

    #expect(result.consolidated.count == 3)
    #expect(result.rejected.isEmpty)
    let assertion = try #require(result.asserted.first)
    #expect(assertion.evidence.count == 3)
    #expect(assertion.value == .string("entry 1 — entry 2 — entry 3"))
    #expect(assertion.category == "summaries")
    #expect(assertion.validFrom == at(3))
  }
}

@Test func theDigestIsOrderedOldestFirstAndBounded() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "newest", occurredAt: at(9)))
    try store.record(EvidenceDraft(text: "oldest", occurredAt: at(1)))

    let bounded = try store.consolidate(
      .matching(kinds: ["message"]),
      using: DigestConsolidator(slot: digest, maximumLength: 8))
    #expect(bounded.asserted[0].value == .string("oldest"))
  }
}

@Test func consolidationSelectsNothingQuietly() throws {
  try withStore { store in
    let result = try store.consolidate(
      .matching(query: "nothing matches this"), using: DigestConsolidator(slot: digest))
    #expect(result.consolidated.isEmpty)
    #expect(result.asserted.isEmpty)
    #expect(result.rejected.isEmpty)
  }
}

@Test func aConsolidatorIsNoMoreTrustedThanAnExtractor() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "an entry"))
    let result = try store.consolidate(
      .matching(kinds: ["message"]), using: DigestConsolidator(slot: "not.declared"))
    #expect(result.asserted.isEmpty)
    #expect(result.rejected.map(\.reason) == [.undeclaredSlot("not.declared")])
  }
}

@Test func aThrowingConsolidatorIsReportedNotPropagated() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "an entry"))
    let result = try store.consolidate(.matching(kinds: ["message"]), using: FailingConsolidator())
    #expect(result.asserted.isEmpty)
    #expect(result.rejected.count == 1)
    if case .extractorFailed = result.rejected[0].reason {} else {
      Issue.record("expected extractorFailed, got \(result.rejected[0].reason)")
    }
  }
}

@Test func consolidatingTwiceSupersedesRatherThanDuplicating() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "first", occurredAt: at(1)))
    try store.consolidate(.matching(kinds: ["message"]), using: DigestConsolidator(slot: digest))

    try store.record(EvidenceDraft(text: "second", occurredAt: at(2)))
    try store.consolidate(.matching(kinds: ["message"]), using: DigestConsolidator(slot: digest))

    let current = try store.currentAssertions(in: .global, slot: digest)
    #expect(current.map(\.value) == [.string("first — second")])
    #expect(try store.history(of: digest, in: .global).count == 2)
  }
}

// MARK: - Consolidation meets forgetting

@Test func forgettingOneInputWeakensAConsolidatedAssertion() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "entry one", occurredAt: at(1))).evidence
    try store.record(EvidenceDraft(text: "entry two", occurredAt: at(2)))

    let result = try store.consolidate(
      .matching(kinds: ["message"]), using: DigestConsolidator(slot: digest))
    let assertion = try #require(result.asserted.first)

    let report = try store.forget(.identifiers([first.id]))
    #expect(report.retractedAssertions.isEmpty)
    #expect(report.weakenedAssertions.map(\.id) == [assertion.id])

    let stored = try #require(try store.assertion(assertion.id))
    #expect(stored.state == .current)
    #expect(stored.evidence.count == 1)
  }
}

@Test func forgettingEveryInputRetractsAConsolidatedAssertion() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "entry one", occurredAt: at(1))).evidence
    let second = try store.record(EvidenceDraft(text: "entry two", occurredAt: at(2))).evidence

    let result = try store.consolidate(
      .matching(kinds: ["message"]), using: DigestConsolidator(slot: digest))
    let assertion = try #require(result.asserted.first)

    let report = try store.forget(.identifiers([first.id, second.id]))
    #expect(report.retractedAssertions == [assertion.id])

    let stored = try #require(try store.assertion(assertion.id))
    #expect(stored.state == .retracted)
    // The digest is a verbatim copy of both records, so it has to go too.
    #expect(stored.text.isEmpty)
    #expect(stored.value == .null)
  }
}

private struct FailingConsolidator: Consolidator {
  struct Failure: Error {}
  func consolidate(_ evidence: [Evidence]) throws -> [AssertionProposal] { throw Failure() }
}
