import Foundation
import Testing

@testable import LatticeMemory

@Test func broaderRecordsAreVisibleToNarrowerQueries() {
  let record: Scope = ["project": "acme"]
  #expect(record.isVisible(in: ["project": "acme", "user": "sam"]))
  #expect(record.isVisible(in: ["project": "acme"]))
}

@Test func narrowerRecordsStayHiddenFromBroaderQueries() {
  let record: Scope = ["project": "acme", "user": "sam"]
  #expect(!record.isVisible(in: ["project": "acme"]))
  #expect(record.isVisible(in: ["project": "acme", "user": "sam", "session": "9"]))
}

@Test func mismatchedDimensionValuesAreNeverVisible() {
  #expect(!Scope(["project": "acme"]).isVisible(in: ["project": "other"]))
}

@Test func globalScopeIsVisibleEverywhereButSeesOnlyItself() {
  #expect(Scope.global.isVisible(in: ["project": "acme"]))
  #expect(!Scope(["project": "acme"]).isVisible(in: .global))
}

@Test func storageKeysAreStableAcrossDictionaryOrdering() {
  let first = Scope(["b": "2", "a": "1"])
  let second = Scope(["a": "1", "b": "2"])
  #expect(first.storageKey == second.storageKey)
  #expect(Scope(storageKey: first.storageKey) == first)
}

@Test func storageKeysEscapeTheirOwnDelimiters() {
  // A value containing "&" or "=" must not be able to forge another dimension.
  let scope = Scope(["project": "a=1&user=root", "user": "sam"])
  let restored = Scope(storageKey: scope.storageKey)
  #expect(restored == scope)
  #expect(restored.dimensions["user"] == "sam")
}
