import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private func withStore<T>(_ body: (MemoryStore) throws -> T) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("notes-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let schema: MemorySchema = ["package.manager": SlotRule(kind: .string, category: "tooling")]
  return try body(try MemoryStore(path: path, schema: schema))
}

private func at(_ day: Int) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
}

@Test func pinningAndReadingBackANote() throws {
  try withStore { store in
    store.clock = { at(1) }
    let note = try store.pin("Always mention the safety caveat.", title: "caveat")

    let stored = try #require(try store.note(title: "caveat"))
    #expect(stored == note)
    #expect(stored.text == "Always mention the safety caveat.")
    #expect(stored.updatedAt == at(1))
  }
}

@Test func rePinningEditsInPlaceAndKeepsTheIdentifier() throws {
  try withStore { store in
    let first = try store.pin("first wording", title: "caveat")
    let second = try store.pin("second wording", title: "caveat")

    #expect(second.id == first.id)
    #expect(try store.notes(in: .global).count == 1)
    #expect(try store.note(title: "caveat")?.text == "second wording")
  }
}

@Test func notesInDifferentScopesAreDifferentNotes() throws {
  try withStore { store in
    let broad = try store.pin("broad", title: "caveat", scope: ["project": "a"])
    let narrow = try store.pin("narrow", title: "caveat", scope: ["project": "a", "user": "sam"])

    #expect(broad.id != narrow.id)
    #expect(try store.notes(in: ["project": "a"]).map(\.text) == ["broad"])
    #expect(
      try store.notes(in: ["project": "a", "user": "sam"]).map(\.text).sorted()
        == ["broad", "narrow"])
  }
}

@Test func noteVisibilityFollowsTheUsualScopeRule() throws {
  try withStore { store in
    try store.pin("narrow", title: "caveat", scope: ["project": "a", "user": "sam"])
    #expect(try store.notes(in: ["project": "a"]).isEmpty)
    #expect(try store.notes(in: .global).isEmpty)
  }
}

@Test func unpinningRemovesANote() throws {
  try withStore { store in
    let note = try store.pin("temporary", title: "caveat")
    try store.unpin(note.id)
    #expect(try store.notes(in: .global).isEmpty)
    #expect(throws: MemoryError.unknownRecord(note.id)) { try store.unpin(note.id) }
  }
}

// MARK: - Retrieval

@Test func pinnedNotesAreReturnedWithoutMatchingTheQuery() throws {
  try withStore { store in
    try store.pin("Always mention the safety caveat.", title: "caveat")
    try store.record(EvidenceDraft(text: "an unrelated record about marmalade"))

    let result = try store.retrieve(RetrievalRequest(query: "marmalade", mode: .lexical))
    #expect(result.items.contains { $0.text.contains("safety caveat") })
    #expect(result.sections.first?.title == "Notes")
  }
}

@Test func pinnedNotesGetFirstClaimOnTheBudget() throws {
  try withStore { store in
    try store.pin("the pinned note", title: "caveat")
    for day in 1...3 {
      try store.record(EvidenceDraft(text: "record \(day)", occurredAt: at(day)))
    }

    let result = try store.retrieve(
      RetrievalRequest(mode: .recency, budget: .items(1)))
    #expect(result.items.map(\.text) == ["the pinned note"])
    #expect(result.wasTruncated)
  }
}

@Test func notesAreOmittedWhenNotRequested() throws {
  try withStore { store in
    try store.pin("the pinned note", title: "caveat")
    try store.record(EvidenceDraft(text: "a record"))

    let result = try store.retrieve(
      RetrievalRequest(kinds: [.evidence], mode: .recency))
    #expect(result.items.map(\.text) == ["a record"])
    #expect(result.trace.dropped[.notRequested] == nil)
  }
}

@Test func notesOutsideTheScopeAreNotReturned() throws {
  try withStore { store in
    try store.pin("project b only", title: "caveat", scope: ["project": "b"])
    let result = try store.retrieve(
      RetrievalRequest(scope: ["project": "a"], mode: .recency))
    #expect(result.items.isEmpty)
  }
}

@Test func forgettingLeavesPinnedNotesAlone() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "the passphrase is opensesame")).evidence
    try store.pin("the passphrase is opensesame", title: "reminder")

    try store.forget(.identifiers([evidence.id]))

    // Notes are authored rather than derived, so nothing links them to the
    // record that was forgotten. Repeating its content is the author's problem.
    #expect(try store.note(title: "reminder")?.text == "the passphrase is opensesame")
  }
}
