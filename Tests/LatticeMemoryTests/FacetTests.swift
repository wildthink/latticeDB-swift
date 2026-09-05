import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private let owner: Slot = "owner"

private var facetSchema: MemorySchema {
  [owner: SlotRule(kind: .string, category: "people")]
}

private let sam = Facet("person", "sam")
private let alex = Facet("person", "alex")
private let acme = Facet("project", "acme")

private func withStore<T>(
  embedder: (any TextEmbedder)? = nil, _ body: (MemoryStore) throws -> T
) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("facet-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(try MemoryStore(path: path, schema: facetSchema, embedder: embedder))
}

@discardableResult
private func seed(
  _ store: MemoryStore, _ text: String, facets: Set<Facet> = [], scope: Scope = .global
) throws -> Evidence {
  try store.record(
    EvidenceDraft(kind: "message", text: text, scope: scope, facets: facets)
  ).evidence
}

private func texts(_ result: RetrievalResult) -> [String] {
  result.items.map(\.text)
}

// MARK: - Tagging

@Test func evidenceKeepsTheFacetsItWasTaggedWith() throws {
  try withStore { store in
    let stored = try seed(store, "Sam owns the acme rollout.", facets: [sam, acme])
    #expect(stored.facets == [sam, acme])

    let reread = try store.evidence(stored.id)
    #expect(reread?.facets == [sam, acme])
    let byID = try store.facets(of: stored.id)
    #expect(byID == [sam, acme])
  }
}

@Test func twoKindsMayShareAnIdentifier() throws {
  try withStore { store in
    let ambiguous = Facet("project", "sam")
    let stored = try seed(store, "Both.", facets: [sam, ambiguous])
    #expect(stored.facets.count == 2)

    let people = try store.records(mentioning: [sam])
    let projects = try store.records(mentioning: [ambiguous])
    #expect(people == [stored.id])
    #expect(projects == [stored.id])
  }
}

@Test func aFacetIsSharedByEveryRecordCarryingIt() throws {
  try withStore { store in
    let first = try seed(store, "Sam shipped it.", facets: [sam])
    let second = try seed(store, "Sam reviewed it.", facets: [sam])
    try seed(store, "Nobody in particular.", facets: [])

    let mentioning = try store.records(mentioning: [sam])
    #expect(Set(mentioning) == [first.id, second.id])
    let none = try store.records(mentioning: [])
    #expect(none.isEmpty)
    let unknown = try store.records(mentioning: [Facet("person", "nobody")])
    #expect(unknown.isEmpty)
  }
}

@Test func aConclusionIsAboutWhatItsSourcesWereAbout() throws {
  try withStore { store in
    let source = try seed(store, "Sam owns acme.", facets: [sam, acme])
    let written = try store.assert(
      AssertionProposal(slot: owner, value: .string("sam")), from: source.id)

    // Inherited, not proposed: the extractor never named a facet.
    #expect(written.facets == [sam, acme])
    let mentioning = try store.records(mentioning: [acme])
    #expect(Set(mentioning) == [source.id, written.id])
  }
}

@Test func aConclusionFromSeveralSourcesTakesTheirUnion() throws {
  try withStore { store in
    let first = try seed(store, "Sam was there.", facets: [sam])
    let second = try seed(store, "So was acme.", facets: [acme])
    let written = try store.assert(
      AssertionProposal(slot: owner, value: .string("sam")), from: [first.id, second.id])
    #expect(written.facets == [sam, acme])
  }
}

@Test func askingAboutAnUnknownRecordIsRefused() throws {
  try withStore { store in
    let missing = threw { _ = try store.facets(of: RecordID("nope")) }
    #expect(missing)
  }
}

private func threw(_ body: () throws -> Void) -> Bool {
  do {
    try body()
    return false
  } catch {
    return true
  }
}

// MARK: - Ranking

@Test func facetsRankWithoutAQuery() throws {
  try withStore { store in
    try seed(store, "Unrelated chatter.", facets: [])
    try seed(store, "Sam shipped it.", facets: [sam])

    let result = try store.retrieve(RetrievalRequest(kinds: .evidence, facets: [sam]))
    // Facets alone are enough to rank on, so this is not a recency fallback.
    #expect(result.trace.mode != .recency)
    #expect(texts(result).first == "Sam shipped it.")
    #expect(result.trace.laneCoverage[.facet] == 1)
  }
}

@Test func facetsRankRatherThanFilter() throws {
  try withStore { store in
    try seed(store, "Frankfurt deployment notes.", facets: [])
    try seed(store, "Sam on Frankfurt.", facets: [sam])

    let result = try store.retrieve(
      RetrievalRequest(query: "Frankfurt", kinds: .evidence, facets: [sam], mode: .lexical))
    // The untagged record still comes back; the tagged one just leads.
    #expect(texts(result).count == 2)
    #expect(texts(result).first == "Sam on Frankfurt.")
  }
}

@Test func matchingMoreFacetsOutranksMatchingFewer() throws {
  try withStore { store in
    try seed(store, "Only Sam.", facets: [sam])
    try seed(store, "Sam and acme.", facets: [sam, acme])

    let result = try store.retrieve(
      RetrievalRequest(kinds: .evidence, facets: [sam, acme]))
    #expect(texts(result).first == "Sam and acme.")
  }
}

@Test func weightsDecideWhichKindCounts() throws {
  try withStore { store in
    try seed(store, "Only Sam.", facets: [sam])
    try seed(store, "Only acme.", facets: [acme])

    let byPerson = try store.retrieve(
      RetrievalRequest(
        kinds: .evidence, facets: [sam, acme], facetWeights: ["person": 4, "project": 1]))
    #expect(texts(byPerson).first == "Only Sam.")

    let byProject = try store.retrieve(
      RetrievalRequest(
        kinds: .evidence, facets: [sam, acme], facetWeights: ["person": 1, "project": 4]))
    #expect(texts(byProject).first == "Only acme.")
  }
}

@Test func theFacetLaneNamesItselfInTheExplanation() throws {
  try withStore { store in
    try seed(store, "Sam shipped it.", facets: [sam])
    let result = try store.retrieve(RetrievalRequest(kinds: .evidence, facets: [sam]))
    let item = try #require(result.items.first)
    let lanes = item.explanation.lanes
    #expect(lanes == [.facet])
  }
}

@Test func theFacetLaneFusesWithTheQueryLanes() throws {
  try withStore(embedder: HashEmbedder(dimensions: 64)) { store in
    try seed(store, "Sam on Frankfurt.", facets: [sam])
    let result = try store.retrieve(
      RetrievalRequest(query: "Frankfurt", kinds: .evidence, facets: [sam], mode: .hybrid))
    let item = try #require(result.items.first)
    let lanes = Set(item.explanation.lanes)
    #expect(lanes == [.lexical, .vector, .facet])
  }
}

@Test func facetsOutsideTheScopeStayHidden() throws {
  try withStore { store in
    try seed(store, "Sam, privately.", facets: [sam], scope: ["user": "sam"])
    let result = try store.retrieve(RetrievalRequest(kinds: .evidence, facets: [sam]))
    #expect(result.items.isEmpty)
    #expect(result.trace.dropped[.outOfScope] == 1)
  }
}

@Test func anUntaggedRequestRanksByRecencyAsBefore() throws {
  try withStore { store in
    try seed(store, "First.", facets: [sam])
    let result = try store.retrieve(RetrievalRequest(kinds: .evidence))
    #expect(result.trace.mode == .recency)
    #expect(result.trace.laneCoverage.isEmpty)
  }
}

// MARK: - Forgetting

@Test func forgettingTakesTheFacetsWithIt() throws {
  try withStore { store in
    let stored = try seed(store, "Sam shipped it.", facets: [sam, acme])
    try store.forget(ForgetRequest(identifiers: [stored.id]))

    // What a record was about is as revealing as what it said.
    let remaining = try store.facets(of: stored.id)
    #expect(remaining.isEmpty)
    let mentioning = try store.records(mentioning: [sam])
    #expect(mentioning.isEmpty)
  }
}

@Test func aFacetStillInUseSurvivesAnotherRecordsForgetting() throws {
  try withStore { store in
    let forgotten = try seed(store, "Sam here.", facets: [sam])
    let kept = try seed(store, "Sam there.", facets: [sam])
    try store.forget(ForgetRequest(identifiers: [forgotten.id]))

    let mentioning = try store.records(mentioning: [sam])
    #expect(mentioning == [kept.id])
  }
}

@Test func explicitRecencyIgnoresFacetsAsItIgnoresEverythingElse() throws {
  try withStore { store in
    try seed(store, "Untagged, and newest.", facets: [])
    let result = try store.retrieve(
      RetrievalRequest(kinds: .evidence, facets: [sam], mode: .recency))
    // Asking for the newest records means asking for no relevance signal at all.
    #expect(result.trace.mode == .recency)
    #expect(result.trace.laneCoverage.isEmpty)
    #expect(texts(result) == ["Untagged, and newest."])
  }
}
