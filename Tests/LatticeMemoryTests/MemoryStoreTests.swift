import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

// MARK: - Fixtures

private let packageManager: Slot = "package.manager"
private let testCommand: Slot = "project.test_command"
private let topic: Slot = "document.topic"

private var schema: MemorySchema {
  [
    packageManager: SlotRule(
      kind: .string, category: "tooling", allowedValues: ["npm", "pnpm", "yarn"]),
    testCommand: SlotRule(kind: .string, category: "tooling", requiresQuote: true),
    topic: SlotRule(cardinality: .multiple, kind: .string, category: "content"),
  ]
}

private var patternExtractor: PatternExtractor {
  PatternExtractor([
    .init(
      slot: packageManager,
      pattern: #/(?:use|using|switched to|switching to)\s+(npm|pnpm|yarn)\b/#.ignoresCase()),
    .init(slot: testCommand, pattern: #/tests? run with `([^`]+)`/#.ignoresCase()),
  ])
}

/// Runs `body` with a store at a fresh temporary path, removed afterwards.
private func withStore<T>(
  schema: MemorySchema = schema, extractors: [any Extractor] = [], _ body: (MemoryStore) throws -> T
) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("memory-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(try MemoryStore(path: path, schema: schema, extractors: extractors))
}

private func at(_ day: Int) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
}

// MARK: - Evidence

@Test func recordedEvidenceReadsBackUnchanged() throws {
  try withStore { store in
    let result = try store.record(
      EvidenceDraft(
        kind: "commit", text: "Switched to pnpm.", scope: ["project": "acme"],
        occurredAt: at(1), metadata: ["author": .string("sam"), "files": .integer(3)]))

    let stored = try #require(try store.evidence(result.evidence.id))
    #expect(stored.kind == "commit")
    #expect(stored.text == "Switched to pnpm.")
    #expect(stored.scope == ["project": "acme"])
    #expect(stored.occurredAt == at(1))
    #expect(stored.metadata == ["author": .string("sam"), "files": .integer(3)])
  }
}

@Test func evidenceWithoutAnOccurrenceTimeUsesTheRecordingTime() throws {
  try withStore { store in
    store.clock = { at(5) }
    let result = try store.record(EvidenceDraft(text: "no timestamp"))
    #expect(result.evidence.occurredAt == at(5))
    #expect(result.evidence.recordedAt == at(5))
  }
}

@Test func recordingACallerIdentifierTwiceIsRefused() throws {
  try withStore { store in
    let id = RecordID("upstream-42")
    try store.record(EvidenceDraft(text: "first", id: id))
    #expect(throws: MemoryError.duplicateIdentifier(id)) {
      try store.record(EvidenceDraft(text: "again", id: id))
    }
  }
}

@Test func generatedIdentifiersCarryTheirKindAndSortByTime() {
  let early = RecordID.generate(prefix: "ev", now: at(1))
  let late = RecordID.generate(prefix: "ev", now: at(2))
  #expect(early.prefix == "ev")
  #expect(early.rawValue < late.rawValue)
}

// MARK: - Extraction and validation

@Test func patternExtractionWritesAQuotedAssertion() throws {
  try withStore(extractors: [patternExtractor]) { store in
    let result = try store.record(
      EvidenceDraft(text: "We are switching to pnpm next week.", scope: ["project": "acme"]))

    #expect(result.rejected.isEmpty)
    let assertion = try #require(result.asserted.first)
    #expect(assertion.slot == packageManager)
    #expect(assertion.value == .string("pnpm"))
    #expect(assertion.category == "tooling")
    #expect(assertion.quote == "switching to pnpm")
    #expect(assertion.evidence == [result.evidence.id])
  }
}

@Test func aQuoteIsAlwaysVerbatimInItsEvidence() throws {
  try withStore(extractors: [patternExtractor]) { store in
    let result = try store.record(EvidenceDraft(text: "Tests run with `swift test` here."))
    let assertion = try #require(result.asserted.first)
    let quote = try #require(assertion.quote)
    #expect(result.evidence.text.contains(quote))
    #expect(assertion.value == .string("swift test"))
  }
}

@Test func undeclaredSlotsAreRejectedNotWritten() throws {
  let proposal = AssertionProposal(slot: "not.declared", value: .string("x"))
  try withStore(extractors: [ProposingExtractor([proposal])]) { store in
    let result = try store.record(EvidenceDraft(text: "anything"))
    #expect(result.asserted.isEmpty)
    #expect(result.rejected.map(\.reason) == [.undeclaredSlot("not.declared")])
  }
}

@Test func wrongValueKindsAreRejected() throws {
  try withStore(extractors: [ProposingExtractor([.init(slot: packageManager, value: .integer(7))])])
  { store in
    let result = try store.record(EvidenceDraft(text: "anything"))
    #expect(result.rejected.map(\.reason) == [.wrongValueKind(expected: .string, actual: .integer)])
  }
}

@Test func valuesOutsideTheAllowedSetAreRejected() throws {
  try withStore(
    extractors: [ProposingExtractor([.init(slot: packageManager, value: .string("bun"))])]
  ) { store in
    let result = try store.record(EvidenceDraft(text: "anything"))
    #expect(result.rejected.map(\.reason) == [.disallowedValue("bun")])
  }
}

@Test func inventedQuotesAreRejected() throws {
  try withStore(
    extractors: [
      ProposingExtractor([
        .init(slot: packageManager, value: .string("pnpm"), quote: "text that is not there")
      ])
    ]
  ) { store in
    let result = try store.record(EvidenceDraft(text: "We use pnpm."))
    #expect(result.asserted.isEmpty)
    #expect(result.rejected.map(\.reason) == [.unfaithfulQuote("text that is not there")])
  }
}

@Test func aRequiredQuoteMustBePresent() throws {
  let proposal = AssertionProposal(slot: testCommand, value: .string("make"))
  try withStore(extractors: [ProposingExtractor([proposal])]) { store in
    let result = try store.record(EvidenceDraft(text: "run make"))
    #expect(result.rejected.map(\.reason) == [.missingQuote])
  }
}

@Test func proposalsCannotEscapeTheirEvidenceScope() throws {
  let escaping = AssertionProposal(
    slot: packageManager, value: .string("pnpm"), scope: ["project": "other"])
  try withStore(extractors: [ProposingExtractor([escaping])]) { store in
    let result = try store.record(
      EvidenceDraft(text: "We use pnpm.", scope: ["project": "acme"]))
    #expect(result.asserted.isEmpty)
    #expect(
      result.rejected.map(\.reason)
        == [.scopeEscapesEvidence(proposed: ["project": "other"], evidence: ["project": "acme"])])
  }
}

@Test func proposalsMayNarrowTheirEvidenceScope() throws {
  let narrowing = AssertionProposal(
    slot: packageManager, value: .string("pnpm"), scope: ["project": "acme", "user": "sam"])
  try withStore(extractors: [ProposingExtractor([narrowing])]) { store in
    let result = try store.record(
      EvidenceDraft(text: "We use pnpm.", scope: ["project": "acme"]))
    #expect(result.asserted.first?.scope == ["project": "acme", "user": "sam"])
    #expect(try store.currentAssertions(in: ["project": "acme"]).isEmpty)
    #expect(try store.currentAssertions(in: ["project": "acme", "user": "sam"]).count == 1)
  }
}

@Test func aThrowingExtractorDoesNotLoseTheEvidence() throws {
  try withStore(extractors: [FailingExtractor(), patternExtractor]) { store in
    let result = try store.record(EvidenceDraft(text: "We use pnpm."))
    #expect(try store.evidence(result.evidence.id) != nil)
    #expect(result.asserted.count == 1)
    #expect(result.rejected.count == 1)
    if case .extractorFailed = result.rejected[0].reason {} else {
      Issue.record("expected an extractorFailed rejection, got \(result.rejected[0].reason)")
    }
  }
}

// MARK: - Supersession and history

@Test func aNewValueSupersedesTheOldWithoutLosingIt() throws {
  try withStore(extractors: [patternExtractor]) { store in
    let first = try store.record(
      EvidenceDraft(text: "We use npm.", scope: ["project": "acme"], occurredAt: at(1)))
    let second = try store.record(
      EvidenceDraft(text: "We switched to pnpm.", scope: ["project": "acme"], occurredAt: at(3)))

    #expect(second.superseded == [first.asserted[0].id])

    let current = try store.currentAssertions(in: ["project": "acme"])
    #expect(current.map(\.value) == [.string("pnpm")])

    let history = try store.history(of: packageManager, in: ["project": "acme"])
    #expect(history.map(\.value) == [.string("pnpm"), .string("npm")])
    #expect(history[1].state == .superseded)
    #expect(history[1].validTo == at(3))
    #expect(history[0].validTo == nil)
  }
}

@Test func historicalReadsAnswerFromTheValidInterval() throws {
  try withStore(extractors: [patternExtractor]) { store in
    try store.record(
      EvidenceDraft(text: "We use npm.", scope: ["project": "acme"], occurredAt: at(1)))
    try store.record(
      EvidenceDraft(text: "We switched to pnpm.", scope: ["project": "acme"], occurredAt: at(3)))

    #expect(try store.assertions(validAt: at(2), in: ["project": "acme"]).map(\.value)
      == [.string("npm")])
    #expect(try store.assertions(validAt: at(4), in: ["project": "acme"]).map(\.value)
      == [.string("pnpm")])
    // The interval is half-open, so the instant of replacement belongs to the new value.
    #expect(try store.assertions(validAt: at(3), in: ["project": "acme"]).map(\.value)
      == [.string("pnpm")])
    #expect(try store.assertions(validAt: at(0), in: ["project": "acme"]).isEmpty)
  }
}

@Test func restatingTheCurrentValueChangesNothing() throws {
  try withStore(extractors: [patternExtractor]) { store in
    try store.record(
      EvidenceDraft(text: "We use pnpm.", scope: ["project": "acme"], occurredAt: at(1)))
    let repeated = try store.record(
      EvidenceDraft(text: "Still using pnpm.", scope: ["project": "acme"], occurredAt: at(2)))

    #expect(repeated.asserted.isEmpty)
    #expect(repeated.superseded.isEmpty)
    #expect(try store.history(of: packageManager, in: ["project": "acme"]).count == 1)
  }
}

@Test func supersessionIsScopedAndDoesNotCrossProjects() throws {
  try withStore(extractors: [patternExtractor]) { store in
    try store.record(
      EvidenceDraft(text: "We use npm.", scope: ["project": "a"], occurredAt: at(1)))
    try store.record(
      EvidenceDraft(text: "We use yarn.", scope: ["project": "b"], occurredAt: at(2)))

    #expect(try store.currentAssertions(in: ["project": "a"]).map(\.value) == [.string("npm")])
    #expect(try store.currentAssertions(in: ["project": "b"]).map(\.value) == [.string("yarn")])
  }
}

@Test func multiValuedSlotsAccumulateRatherThanSupersede() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "about kilns and clay")).evidence
    try store.assert(AssertionProposal(slot: topic, value: .string("kilns")), from: evidence.id)
    try store.assert(AssertionProposal(slot: topic, value: .string("clay")), from: evidence.id)

    let current = try store.currentAssertions(in: .global, slot: topic)
    let values = current.map(\.value).sorted { "\($0)" < "\($1)" }
    #expect(values == [.string("clay"), .string("kilns")])
  }
}

@Test func retractingClosesAnAssertionWithoutReplacingIt() throws {
  try withStore(extractors: [patternExtractor]) { store in
    store.clock = { at(9) }
    let result = try store.record(EvidenceDraft(text: "We use pnpm.", occurredAt: at(1)))
    let assertion = try #require(result.asserted.first)

    try store.retract(assertion.id)
    #expect(try store.currentAssertions(in: .global).isEmpty)

    let stored = try #require(try store.assertion(assertion.id))
    #expect(stored.state == .retracted)
    #expect(stored.validTo == at(9))
    #expect(!stored.held(at: at(5)))
  }
}

// MARK: - Provenance

@Test func provenanceIsTraceableInBothDirections() throws {
  try withStore(extractors: [patternExtractor]) { store in
    let result = try store.record(EvidenceDraft(text: "We use pnpm.", occurredAt: at(1)))
    let assertion = try #require(result.asserted.first)

    #expect(try store.evidence(supporting: assertion.id).map(\.id) == [result.evidence.id])
    #expect(try store.assertions(derivedFrom: result.evidence.id).map(\.id) == [assertion.id])
  }
}

@Test func supersededAssertionsStillNameTheEvidenceForThem() throws {
  try withStore(extractors: [patternExtractor]) { store in
    let first = try store.record(EvidenceDraft(text: "We use npm.", occurredAt: at(1)))
    try store.record(EvidenceDraft(text: "We switched to pnpm.", occurredAt: at(3)))

    let derived = try store.assertions(derivedFrom: first.evidence.id)
    #expect(derived.map(\.state) == [.superseded])
    #expect(derived[0].evidence == [first.evidence.id])
  }
}

@Test func provenanceQueriesRejectUnknownRecords() throws {
  try withStore { store in
    #expect(throws: MemoryError.unknownRecord(RecordID("nope"))) {
      try store.assertions(derivedFrom: RecordID("nope"))
    }
  }
}

// MARK: - Direct assertion

@Test func directAssertionIsValidatedLikeAnExtractedOne() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "We use pnpm.")).evidence

    let written = try store.assert(
      AssertionProposal(slot: packageManager, value: .string("pnpm"), quote: "pnpm"),
      from: evidence.id)
    #expect(written.value == .string("pnpm"))

    #expect(throws: Rejection.self) {
      try store.assert(
        AssertionProposal(slot: packageManager, value: .string("bun")), from: evidence.id)
    }
    #expect(throws: MemoryError.unknownRecord(RecordID("missing"))) {
      try store.assert(
        AssertionProposal(slot: packageManager, value: .string("npm")), from: RecordID("missing"))
    }
  }
}

// MARK: - Reads

@Test func categoryFiltersRestrictToOneGroupOfSlots() throws {
  try withStore(extractors: [patternExtractor]) { store in
    let result = try store.record(
      EvidenceDraft(text: "We use pnpm. Tests run with `swift test`.", occurredAt: at(1)))
    try store.assert(
      AssertionProposal(slot: topic, value: .string("tooling notes")), from: result.evidence.id)

    #expect(try store.currentAssertions(in: .global, category: "tooling").count == 2)
    #expect(try store.currentAssertions(in: .global, category: "content").count == 1)
    #expect(try store.currentAssertions(in: .global).count == 3)
  }
}

@Test func evidenceAndAssertionsAreFullTextSearchable() throws {
  try withStore(extractors: [patternExtractor]) { store in
    try store.record(EvidenceDraft(text: "We switched to pnpm for the monorepo."))
    let hits = try store.database.fullTextSearch("monorepo", label: "Evidence", property: "text")
    #expect(hits.count == 1)
  }
}

@Test func aMissingRecordReadsAsNil() throws {
  try withStore { store in
    let evidence = try store.evidence(RecordID("nope"))
    let assertion = try store.assertion(RecordID("nope"))
    #expect(evidence == nil)
    #expect(assertion == nil)
  }
}

// MARK: - Test extractors

/// Returns fixed proposals, so validation can be tested without a pattern that
/// would refuse to produce the bad proposal in the first place.
private struct ProposingExtractor: Extractor {
  let proposals: [AssertionProposal]
  init(_ proposals: [AssertionProposal]) { self.proposals = proposals }
  func extract(from evidence: Evidence) throws -> [AssertionProposal] { proposals }
}

private struct FailingExtractor: Extractor {
  struct Failure: Error {}
  func extract(from evidence: Evidence) throws -> [AssertionProposal] { throw Failure() }
}
