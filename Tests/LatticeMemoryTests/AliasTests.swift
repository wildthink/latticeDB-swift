import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private let packageManager: Slot = "package.manager"
private let deployTarget: Slot = "deploy.target"
private let tag: Slot = "tag"

private var aliasSchema: MemorySchema {
  [
    packageManager: SlotRule(kind: .string, allowedValues: ["npm", "pnpm", "yarn"]),
    deployTarget: SlotRule(kind: .string),
    tag: SlotRule(cardinality: .multiple, kind: .string),
  ]
}

private func withStore<T>(_ body: (MemoryStore) throws -> T) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("alias-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(try MemoryStore(path: path, schema: aliasSchema))
}

/// Records evidence and returns its identifier.
private func evidence(_ store: MemoryStore, _ text: String) throws -> RecordID {
  try store.record(EvidenceDraft(kind: "message", text: text)).evidence.id
}

/// Whether `body` threw, without letting a closure follow a testing macro.
private func threw(_ body: () throws -> Void) -> Bool {
  do {
    try body()
    return false
  } catch {
    return true
  }
}

// MARK: - Normalization

@Test func normalizationKeepsTheCharactersIdentifiersAreBuiltFrom() {
  #expect(Alias.normalize("  MMI  ") == "mmi")
  #expect(Alias.normalize("macOS-MultiDoc-Client") == "macos-multidoc-client")
  #expect(Alias.normalize("package.manager") == "package.manager")
  #expect(Alias.normalize("slot:deploy.target") == "slot:deploy.target")
  #expect(Alias.normalize("Flat   tire!") == "flat tire")
  #expect(Alias.normalize("(a), [b]") == "a b")
  #expect(Alias.normalize("   ") == "")
}

// MARK: - The table

@Test func anAliasResolvesWithinItsNamespaceOnly() throws {
  try withStore { store in
    try store.alias("MMI", to: "macos-multidoc-client", in: .query)
    let exact = try store.canonical(for: "mmi", in: .query)
    // The alias is matched normalized, so the caller need not normalize first.
    let padded = try store.canonical(for: "  MMI ", in: .query)
    let otherNamespace = try store.canonical(for: "mmi", in: .values(of: deployTarget))
    let unmapped = try store.canonical(for: "unmapped", in: .query)
    #expect(exact == "macos-multidoc-client")
    #expect(padded == "macos-multidoc-client")
    #expect(otherNamespace == nil)
    #expect(unmapped == nil)
  }
}

@Test func writingAnAliasAgainReplacesIt() throws {
  try withStore { store in
    try store.alias("fra", to: "frankfurt", in: .query)
    try store.alias("fra", to: "frankfurt-am-main", in: .query)
    let resolved = try store.canonical(for: "fra", in: .query)
    let count = try store.aliases(in: .query).count
    #expect(resolved == "frankfurt-am-main")
    #expect(count == 1)
  }
}

@Test func unaliasingRemovesTheMapping() throws {
  try withStore { store in
    try store.alias("fra", to: "frankfurt", in: .query)
    try store.unalias("FRA", in: .query)
    let resolved = try store.canonical(for: "fra", in: .query)
    let remaining = try store.aliases()
    #expect(resolved == nil)
    #expect(remaining.isEmpty)
    // Removing something unmapped is not an error.
    try store.unalias("never-mapped", in: .query)
  }
}

@Test func listingIsOrderedAndScopedToANamespace() throws {
  try withStore { store in
    try store.alias("b", to: "beta", in: .query)
    try store.alias("a", to: "alpha", in: .query)
    try store.alias("a", to: "alpha-slot", in: .values(of: deployTarget))

    let inQuery = try store.aliases(in: .query).map(\.alias)
    let all = try store.aliases()
    let namespaces = all.map(\.namespace.rawValue)
    #expect(inQuery == ["a", "b"])
    #expect(all.count == 3)
    #expect(namespaces == ["query", "query", "slot:deploy.target"])
  }
}

@Test func chainsResolveAndCyclesTerminate() throws {
  try withStore { store in
    try store.alias("a", to: "b", in: .query)
    try store.alias("b", to: "c", in: .query)
    let chained = try store.canonical(for: "a", in: .query)
    #expect(chained == "c")

    // a -> b -> c -> a is a loop; resolution stops rather than spinning.
    try store.alias("c", to: "a", in: .query)
    let looped = try store.canonical(for: "a", in: .query)
    #expect(looped != nil)
  }
}

@Test func anEmptyAliasIsRefused() throws {
  try withStore { store in
    let emptyAlias = threw { try store.alias("", to: "something", in: .query) }
    let blankAlias = threw { try store.alias("  ", to: "something", in: .query) }
    let emptyTarget = threw { try store.alias("something", to: "", in: .query) }
    let remaining = try store.aliases()
    #expect(emptyAlias)
    #expect(blankAlias)
    #expect(emptyTarget)
    #expect(remaining.isEmpty)
  }
}

@Test func aTermMappedToItsOwnNormalFormFoldsEveryVariantOntoIt() throws {
  try withStore { store in
    // The key is normalized and the canonical spelling is not, so this is how a
    // preferred spelling is declared. It is not a no-op and it does not loop.
    try store.alias("PNPM", to: "pnpm", in: .query)
    let shouted = try store.canonical(for: "PNPM", in: .query)
    let punctuated = try store.canonical(for: "pnpm!", in: .query)
    #expect(shouted == "pnpm")
    #expect(punctuated == "pnpm")
  }
}

// MARK: - Applied on the way in

@Test func aStringValueIsStoredInItsCanonicalForm() throws {
  try withStore { store in
    try store.alias("PNPM", to: "pnpm", in: .values(of: packageManager))
    let source = try evidence(store, "We switched to PNPM.")
    let written = try store.assert(
      AssertionProposal(slot: packageManager, value: .string("PNPM")), from: source)

    #expect(written.value == .string("pnpm"))
    // The wording the proposal arrived with survives; only the value is
    // canonicalized.
    #expect(written.text == "PNPM")
  }
}

@Test func anAliasSatisfiesAllowedValues() throws {
  try withStore { store in
    let source = try evidence(store, "We switched to PNPM.")
    // Without the alias the value is not one the slot permits.
    let refused = threw {
      try store.assert(
        AssertionProposal(slot: packageManager, value: .string("PNPM")), from: source)
    }
    #expect(refused)

    try store.alias("PNPM", to: "pnpm", in: .values(of: packageManager))
    let written = try store.assert(
      AssertionProposal(slot: packageManager, value: .string("PNPM")), from: source)
    #expect(written.value == .string("pnpm"))
  }
}

@Test func aliasedValuesAreRecognizedAsAlreadyCurrent() throws {
  try withStore { store in
    try store.alias("K8s", to: "kubernetes", in: .values(of: tag))
    let source = try evidence(store, "Tagged kubernetes, also K8s.")
    try store.assert(AssertionProposal(slot: tag, value: .string("kubernetes")), from: source)

    // The second write is the same value under another name, so it is a no-op
    // rather than a duplicate on a multi-valued slot.
    let duplicate = threw {
      try store.assert(AssertionProposal(slot: tag, value: .string("K8s")), from: source)
    }
    #expect(duplicate)
    let current = try store.currentAssertions(in: .global, slot: tag)
    #expect(current.count == 1)
  }
}

@Test func aliasesDoNotRewriteWhatIsAlreadyStored() throws {
  try withStore { store in
    let source = try evidence(store, "Deployments go to fra.")
    let before = try store.assert(
      AssertionProposal(slot: deployTarget, value: .string("fra")), from: source)
    #expect(before.value == .string("fra"))

    try store.alias("fra", to: "frankfurt", in: .values(of: deployTarget))
    let reread = try store.assertion(before.id)
    #expect(reread?.value == .string("fra"))
  }
}

@Test func aNonStringValueIsLeftAlone() throws {
  try withStore { store in
    var schema = aliasSchema
    schema.declare("count", SlotRule(kind: .integer))
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("alias-int-\(UUID().uuidString).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let numeric = try MemoryStore(path: path, schema: schema)

    try numeric.alias("7", to: "8", in: .values(of: "count"))
    let source = try evidence(numeric, "There are 7.")
    let written = try numeric.assert(
      AssertionProposal(slot: "count", value: .integer(7)), from: source)
    #expect(written.value == .integer(7))
  }
}

// MARK: - Applied to the query

@Test func aQueryNamingAnAliasFindsWhatItStandsFor() throws {
  try withStore { store in
    try evidence(store, "Deployments go to the Frankfurt region.")

    let missed = try store.retrieve(RetrievalRequest(query: "fra", mode: .lexical))
    #expect(missed.items.isEmpty)

    try store.alias("fra", to: "Frankfurt", in: .query)
    let found = try store.retrieve(RetrievalRequest(query: "fra", mode: .lexical))
    #expect(!found.items.isEmpty)
  }
}

@Test func expansionAppendsRatherThanSubstitutes() throws {
  try withStore { store in
    try store.alias("mmi", to: "macos-multidoc-client", in: .query)
    let expanded = try store.expandQuery("mmi")
    #expect(expanded.contains("mmi"))
    #expect(expanded.contains("macos-multidoc-client"))
  }
}

@Test func aMultiWordAliasResolvesFromTheWholeQuery() throws {
  try withStore { store in
    try store.alias("flat tire", to: "roadside-tire-change", in: .query)
    let whole = try store.expandQuery("flat tire")
    // A single word of it is not the alias.
    let partial = try store.expandQuery("flat")
    #expect(whole.contains("roadside-tire-change"))
    #expect(partial == "flat")
  }
}

@Test func expansionAddsNothingItAlreadyHas() throws {
  try withStore { store in
    let untouched = try store.expandQuery("frankfurt")
    #expect(untouched == "frankfurt")

    try store.alias("fra", to: "frankfurt", in: .query)
    // The canonical term is already in the query, so repeating it would only
    // weight the same word twice.
    let alreadyPresent = try store.expandQuery("fra frankfurt")
    let empty = try store.expandQuery("")
    #expect(alreadyPresent == "fra frankfurt")
    #expect(empty == "")
  }
}
