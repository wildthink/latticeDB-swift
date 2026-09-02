import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private let packageManager: Slot = "package.manager"
private let deployTarget: Slot = "deploy.target"

private var retrievalSchema: MemorySchema {
  [
    packageManager: SlotRule(kind: .string, category: "tooling"),
    deployTarget: SlotRule(kind: .string, category: "operations"),
  ]
}

private func withStore<T>(
  embedder: (any TextEmbedder)? = nil, _ body: (MemoryStore) throws -> T
) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("retrieval-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(
    try MemoryStore(path: path, schema: retrievalSchema, embedder: embedder))
}

private func at(_ day: Int) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
}

/// Records evidence and an assertion drawn from it, in one scope.
@discardableResult
private func seed(
  _ store: MemoryStore, text: String, slot: Slot = packageManager, value: String,
  scope: Scope = .global, kind: String = "message", day: Int = 1
) throws -> IngestResult {
  let result = try store.record(
    EvidenceDraft(kind: kind, text: text, scope: scope, occurredAt: at(day)))
  try store.assert(
    AssertionProposal(slot: slot, value: .string(value), text: "\(slot) = \(value)"),
    from: result.evidence.id)
  return result
}

// MARK: - Ranking

@Test func lexicalRetrievalRanksByRelevanceToTheQuery() throws {
  try withStore { store in
    try seed(store, text: "The repository uses pnpm for everything.", value: "pnpm")
    try seed(
      store, text: "Deployments go to the Frankfurt region.", slot: deployTarget,
      value: "frankfurt")

    let result = try store.retrieve(RetrievalRequest(query: "Frankfurt", mode: .lexical))
    #expect(result.trace.mode == .lexical)
    #expect(result.items.contains { $0.text.contains("frankfurt") })
    #expect(!result.items.contains { $0.text.contains("pnpm") })
  }
}

@Test func recencyRetrievalNeedsNoQuery() throws {
  try withStore { store in
    try seed(store, text: "older", value: "npm", day: 1)
    try seed(store, text: "newer", value: "pnpm", day: 5)

    let result = try store.retrieve(RetrievalRequest(kinds: .evidence, mode: .recency))
    #expect(result.trace.mode == .recency)
    #expect(result.items.map(\.text) == ["newer", "older"])
  }
}

@Test func automaticModeFollowsTheQueryAndTheEmbedder() throws {
  try withStore { store in
    let withoutQuery = try store.retrieve(RetrievalRequest()).trace.mode
    let withQuery = try store.retrieve(RetrievalRequest(query: "anything")).trace.mode
    #expect(withoutQuery == .recency)
    #expect(withQuery == .lexical)
  }
  try withStore(embedder: HashEmbedder(dimensions: 64)) { store in
    let mode = try store.retrieve(RetrievalRequest(query: "anything")).trace.mode
    #expect(mode == .hybrid)
  }
}

@Test func vectorRetrievalFindsRecordsThroughStoredEmbeddings() throws {
  try withStore(embedder: HashEmbedder(dimensions: 64)) { store in
    try seed(store, text: "Deployments go to the Frankfurt region.", value: "frankfurt")
    let result = try store.retrieve(
      RetrievalRequest(query: "Deployments go to the Frankfurt region.", mode: .vector))
    #expect(result.trace.mode == .vector)
    #expect(!result.items.isEmpty)
  }
}

@Test func vectorRetrievalWithoutAnEmbedderFindsNothing() throws {
  try withStore { store in
    try seed(store, text: "Deployments go to Frankfurt.", value: "frankfurt")
    let result = try store.retrieve(RetrievalRequest(query: "Frankfurt", mode: .vector))
    #expect(result.items.isEmpty)
    #expect(result.trace.candidates == 0)
  }
}

@Test func hybridRetrievalReturnsWhatEitherRankingFound() throws {
  try withStore(embedder: HashEmbedder(dimensions: 64)) { store in
    try seed(store, text: "The repository uses pnpm.", value: "pnpm")
    let result = try store.retrieve(RetrievalRequest(query: "pnpm", mode: .hybrid))
    #expect(result.trace.mode == .hybrid)
    #expect(!result.items.isEmpty)
  }
}

// MARK: - Filtering

@Test func retrievalNeverCrossesScope() throws {
  try withStore { store in
    try seed(store, text: "Project A uses pnpm.", value: "pnpm", scope: ["project": "a"])
    try seed(store, text: "Project B uses yarn.", value: "yarn", scope: ["project": "b"])

    let result = try store.retrieve(
      RetrievalRequest(query: "uses", scope: ["project": "a"], mode: .lexical))
    #expect(result.items.allSatisfy { !$0.text.contains("yarn") })
    #expect(result.trace.dropped[.outOfScope] ?? 0 > 0)
  }
}

@Test func requestedKindsRestrictWhatComesBack() throws {
  try withStore { store in
    try seed(store, text: "The repository uses pnpm.", value: "pnpm")

    let assertionsOnly = try store.retrieve(
      RetrievalRequest(query: "pnpm", kinds: .assertions, mode: .lexical))
    #expect(
      assertionsOnly.items.allSatisfy {
        if case .assertion = $0.record { return true } else { return false }
      })

    let evidenceOnly = try store.retrieve(
      RetrievalRequest(query: "pnpm", kinds: .evidence, mode: .lexical))
    #expect(
      evidenceOnly.items.allSatisfy {
        if case .evidence = $0.record { return true } else { return false }
      })
  }
}

@Test func slotAndCategoryFiltersNarrowAssertions() throws {
  try withStore { store in
    try seed(store, text: "uses pnpm", value: "pnpm")
    try seed(store, text: "deploys to frankfurt", slot: deployTarget, value: "frankfurt")

    let bySlot = try store.retrieve(
      RetrievalRequest(kinds: .assertions, slots: [deployTarget], mode: .recency))
    #expect(bySlot.items.count == 1)

    let byCategory = try store.retrieve(
      RetrievalRequest(kinds: .assertions, categories: ["tooling"], mode: .recency))
    #expect(byCategory.items.count == 1)
    #expect(byCategory.items[0].text.contains("pnpm"))
  }
}

@Test func evidenceKindsAndWindowsFilterRawRecords() throws {
  try withStore { store in
    try seed(store, text: "a commit", value: "npm", kind: "commit", day: 1)
    try seed(store, text: "a message", value: "pnpm", kind: "message", day: 9)

    let commits = try store.retrieve(
      RetrievalRequest(kinds: .evidence, evidenceKinds: ["commit"], mode: .recency))
    #expect(commits.items.map(\.text) == ["a commit"])

    let window = try store.retrieve(
      RetrievalRequest(kinds: .evidence, occurredIn: at(5)..<at(20), mode: .recency))
    #expect(window.items.map(\.text) == ["a message"])
    #expect(window.trace.dropped[.outsideWindow] == 1)
  }
}

@Test func supersededAssertionsAreExcludedUntilAskedForByTime() throws {
  try withStore { store in
    try seed(store, text: "uses npm", value: "npm", day: 1)
    try seed(store, text: "uses pnpm", value: "pnpm", day: 5)

    let now = try store.retrieve(RetrievalRequest(kinds: .assertions, mode: .recency))
    #expect(now.items.count == 1)
    #expect(now.items[0].text.contains("pnpm"))
    #expect(now.trace.dropped[.notValidThen] == 1)

    let then = try store.retrieve(
      RetrievalRequest(kinds: .assertions, validAt: at(3), mode: .recency))
    #expect(then.items.count == 1)
    #expect(then.items[0].text.contains("npm"))
  }
}

// MARK: - Suppression and budget

@Test func evidenceCitedByAReturnedAssertionIsSuppressed() throws {
  try withStore { store in
    try seed(store, text: "The repository uses pnpm.", value: "pnpm")

    let suppressed = try store.retrieve(RetrievalRequest(query: "pnpm", mode: .lexical))
    #expect(suppressed.items.count == 1)
    #expect(suppressed.trace.dropped[.citedByAssertion] == 1)

    let both = try store.retrieve(
      RetrievalRequest(query: "pnpm", mode: .lexical, suppressesCitedEvidence: false))
    #expect(both.items.count == 2)
  }
}

@Test func uncitedEvidenceSurvivesSuppression() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "A note nothing was derived from."))
    let result = try store.retrieve(RetrievalRequest(query: "note", mode: .lexical))
    #expect(result.items.count == 1)
    #expect(result.trace.dropped[.citedByAssertion] == nil)
  }
}

@Test func theBudgetFillsInRankOrderAndReportsTheRest() throws {
  try withStore { store in
    for day in 1...5 {
      try store.record(EvidenceDraft(text: "note number \(day)", occurredAt: at(day)))
    }

    let result = try store.retrieve(
      RetrievalRequest(kinds: .evidence, mode: .recency, budget: .items(2)))
    #expect(result.items.count == 2)
    #expect(result.trace.dropped[.overBudget] == 3)
    #expect(result.trace.cost == 2)
    #expect(result.trace.limit == 2)
    #expect(result.wasTruncated)
    #expect(result.trace.warnings.count == 1)
  }
}

@Test func characterBudgetsCountRenderedText() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "aaaaaaaaaa", occurredAt: at(2)))
    try store.record(EvidenceDraft(text: "bbbbbbbbbb", occurredAt: at(1)))

    let result = try store.retrieve(
      RetrievalRequest(kinds: .evidence, mode: .recency, budget: .characters(15)))
    #expect(result.items.map(\.text) == ["aaaaaaaaaa"])
    #expect(result.trace.cost == 10)
  }
}

@Test func customBudgetsMeasureWhateverTheCallerCounts() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one two three four", occurredAt: at(1)))
    try store.record(EvidenceDraft(text: "five six", occurredAt: at(2)))

    // Counting words, not characters: the newer four-word record does not fit.
    let result = try store.retrieve(
      RetrievalRequest(
        kinds: .evidence, mode: .recency,
        budget: .custom(3) { $0.split(separator: " ").count }))
    #expect(result.items.map(\.text) == ["five six"])
    #expect(result.trace.cost == 2)
  }
}

@Test func anUnlimitedBudgetDropsNothing() throws {
  try withStore { store in
    for day in 1...4 { try store.record(EvidenceDraft(text: "note \(day)", occurredAt: at(day))) }
    let result = try store.retrieve(RetrievalRequest(kinds: .evidence, mode: .recency))
    #expect(result.items.count == 4)
    #expect(!result.wasTruncated)
    #expect(result.trace.limit == nil)
  }
}

// MARK: - Sections and trace

@Test func sectionsGroupAssertionsByCategoryThenEvidence() throws {
  try withStore { store in
    try seed(store, text: "uses pnpm", value: "pnpm")
    try seed(store, text: "deploys to frankfurt", slot: deployTarget, value: "frankfurt")
    try store.record(EvidenceDraft(text: "an uncited note", occurredAt: at(9)))

    let result = try store.retrieve(RetrievalRequest(mode: .recency))
    let titles = result.sections.map(\.title)
    #expect(Set(titles) == ["tooling", "operations", "Evidence"])
    #expect(titles.last == "Evidence")
    #expect(result.rendered.contains("- an uncited note"))
  }
}

@Test func theTraceAccountsForEveryDroppedCandidate() throws {
  try withStore { store in
    try seed(store, text: "Project A uses pnpm.", value: "pnpm", scope: ["project": "a"])
    try seed(store, text: "Project B uses yarn.", value: "yarn", scope: ["project": "b"])

    let result = try store.retrieve(
      RetrievalRequest(scope: ["project": "a"], mode: .recency, budget: .items(1)))
    let accounted = result.items.count + result.trace.dropped.values.reduce(0, +)
    #expect(accounted == result.trace.candidates)
  }
}

@Test func anEmptyStoreIsDistinguishableFromAnOverFilteredOne() throws {
  try withStore { store in
    let empty = try store.retrieve(RetrievalRequest(query: "anything", mode: .lexical))
    #expect(empty.trace.candidates == 0)
    #expect(empty.trace.warnings == ["the query matched nothing before filtering"])

    try seed(store, text: "Project A uses pnpm.", value: "pnpm", scope: ["project": "a"])
    let filtered = try store.retrieve(
      RetrievalRequest(query: "pnpm", scope: ["project": "elsewhere"], mode: .lexical))
    #expect(filtered.items.isEmpty)
    #expect(filtered.trace.candidates > 0)
    #expect(filtered.trace.warnings.isEmpty)
  }
}
