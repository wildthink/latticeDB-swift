import Foundation
import LatticeDB

// MARK: - Namespace

/// A named space of alias-to-canonical mappings.
///
/// Namespaces keep unrelated vocabularies apart. `"staging"` may be an alias for
/// a deploy target and, separately, for an environment name, and resolving one
/// must not reach into the other.
public struct AliasNamespace: RawRepresentable, Hashable, Sendable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  /// The namespace holding the value aliases for `slot`.
  ///
  /// Aliases here are applied on the way in: a string value written to `slot` is
  /// replaced by its canonical form before the schema's `allowedValues` are
  /// checked and before supersession compares it with what is already current.
  ///
  /// This is spelled out rather than an initializer because ``Slot`` is
  /// expressible by a string literal, so `AliasNamespace("deploy.target")`
  /// would silently build a namespace of that name instead of that slot's.
  public static func values(of slot: Slot) -> AliasNamespace {
    AliasNamespace("slot:\(slot.rawValue)")
  }

  /// The namespace consulted when expanding retrieval query text.
  ///
  /// Aliases here are applied at read time, and only to the query: a query for
  /// an alias also searches for what it stands for. Stored text is never
  /// rewritten.
  public static let query = AliasNamespace("query")

  public var description: String { rawValue }
}

// MARK: - Alias

/// One alias and the term it stands for.
public struct Alias: Sendable, Equatable {
  /// The vocabulary this mapping belongs to.
  public var namespace: AliasNamespace

  /// The alias, in its ``normalize(_:)``d form. This is what lookups match.
  public var alias: String

  /// What the alias resolves to, kept exactly as it was written.
  public var canonical: String

  public init(namespace: AliasNamespace, alias: String, canonical: String) {
    self.namespace = namespace
    self.alias = alias
    self.canonical = canonical
  }

  /// Reduces a term to the form aliases are matched on.
  ///
  /// Lowercases, replaces every character except letters, digits, `-`, `:` and
  /// `.` with a space, and collapses runs of whitespace. The three survivors are
  /// deliberate: they carry meaning in the identifiers this is most often used
  /// on — `macos-multidoc-client`, `package.manager`, `slot:deploy.target` —
  /// and splitting on them would break the term into pieces that resolve to
  /// nothing.
  ///
  /// Normalization applies to the alias, never to the canonical term, which is
  /// stored and returned exactly as given.
  public static func normalize(_ term: String) -> String {
    let flattened = term.lowercased().unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
      if scalar == "-" || scalar == ":" || scalar == "." { return Character(scalar) }
      return " "
    }
    return String(flattened).split(separator: " ").joined(separator: " ")
  }
}

/// Why an alias could not be written.
public enum AliasError: Error, Sendable, Equatable {
  /// The alias or the canonical term was empty, or normalized to nothing.
  case emptyTerm
}

// MARK: - Store

extension MemoryStore {
  /// Maps `alias` to `canonical` within `namespace`, replacing any mapping the
  /// alias already had.
  ///
  /// The alias is normalized before it is stored; the canonical term is not.
  /// Mapping a term to its own normalized form is the useful degenerate case
  /// rather than a mistake: `alias("PNPM", to: "pnpm", ...)` stores the key
  /// `pnpm` against the canonical spelling `pnpm`, which is what folds `PNPM`,
  /// `Pnpm` and `pnpm!` onto one value. Nothing else declares a preferred
  /// spelling, since ``Alias/normalize(_:)`` shapes lookup keys, never what is
  /// stored.
  ///
  /// Mappings apply from the moment they are written. Assertions already stored
  /// keep the value they were written with — this canonicalizes what arrives
  /// next, it does not rewrite history.
  ///
  /// - Throws: ``AliasError/emptyTerm`` when either side is blank.
  @discardableResult
  public func alias(
    _ alias: String, to canonical: String, in namespace: AliasNamespace
  ) throws -> Alias {
    let normalized = Alias.normalize(alias)
    let target = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !target.isEmpty else { throw AliasError.emptyTerm }
    let entry = Alias(namespace: namespace, alias: normalized, canonical: target)
    try database.write { transaction in
      let node =
        try aliasNode(normalized, in: namespace, in: transaction)
        ?? transaction.createNode(label: Labels.alias)
      try transaction.setProperty(
        Keys.namespace, onNode: node, to: .string(namespace.rawValue))
      try transaction.setProperty(Keys.alias, onNode: node, to: .string(normalized))
      try transaction.setProperty(Keys.canonical, onNode: node, to: .string(target))
    }
    return entry
  }

  /// Removes `alias` from `namespace`, if it is mapped.
  ///
  /// Removing a mapping does not disturb what was written while it was in force.
  public func unalias(_ alias: String, in namespace: AliasNamespace) throws {
    let normalized = Alias.normalize(alias)
    try database.write { transaction in
      guard let node = try aliasNode(normalized, in: namespace, in: transaction) else { return }
      try transaction.deleteNode(node)
    }
  }

  /// Resolves `term` within `namespace`, or returns `nil` when it is not an
  /// alias.
  ///
  /// Chains are followed: with `a` mapped to `b` and `b` to `c`, `a` resolves to
  /// `c`. A cycle stops at the last term reached rather than looping.
  public func canonical(for term: String, in namespace: AliasNamespace) throws -> String? {
    try database.read { transaction in
      try canonical(for: term, in: namespace, in: transaction)
    }
  }

  /// Returns the mappings in `namespace`, or in every namespace when it is
  /// `nil`, ordered by namespace then alias.
  public func aliases(in namespace: AliasNamespace? = nil) throws -> [Alias] {
    try database.read { transaction in
      try transaction.nodeIDs(label: Labels.alias)
        .map { try readAlias($0, in: transaction) }
        .filter { namespace == nil || $0.namespace == namespace }
        .sorted {
          ($0.namespace.rawValue, $0.alias) < ($1.namespace.rawValue, $1.alias)
        }
    }
  }

  // MARK: Resolution

  /// Resolves `term` on a transaction the caller already holds.
  ///
  /// Each hop is an indexed lookup rather than a scan of the namespace, so a
  /// vocabulary of any size costs one lookup per link in the chain.
  func canonical(
    for term: String, in namespace: AliasNamespace, in transaction: Transaction
  ) throws -> String? {
    var current = Alias.normalize(term)
    // The starting term counts as visited, so `a -> b -> a` stops at `a` rather
    // than resolving forever.
    var seen: Set<String> = [current]
    var resolved: String?
    while let node = try aliasNode(current, in: namespace, in: transaction) {
      let next = try readAlias(node, in: transaction).canonical
      resolved = next
      current = Alias.normalize(next)
      if !seen.insert(current).inserted { break }
    }
    return resolved
  }

  /// Returns `proposal` with a string value replaced by its canonical form.
  ///
  /// Only the value is rewritten. ``AssertionProposal/text`` keeps the wording
  /// the proposal arrived with, so the assertion still reads the way it was
  /// said while the value it is compared and superseded on is canonical.
  func canonicalize(
    _ proposal: AssertionProposal, in transaction: Transaction
  ) throws -> AssertionProposal {
    guard case .string(let text) = proposal.value else { return proposal }
    guard
      let canonical = try canonical(
        for: text, in: .values(of: proposal.slot), in: transaction),
      canonical != text
    else { return proposal }
    var resolved = proposal
    resolved.value = .string(canonical)
    return resolved
  }

  /// Returns `query` with the canonical form of every alias it mentions
  /// appended.
  ///
  /// Both the whole query and each of its words are looked up, so a multi-word
  /// alias resolves as readily as a single term. Terms are appended rather than
  /// substituted: the words actually typed still rank, and BM25 treats the
  /// result as the bag of words it is.
  func expandQuery(_ query: String) throws -> String {
    let normalized = Alias.normalize(query)
    guard !normalized.isEmpty else { return query }
    let terms = [normalized] + normalized.split(separator: " ").map(String.init)
    let present = Set(normalized.split(separator: " ").map(String.init))

    var additions: [String] = []
    var added: Set<String> = []
    try database.read { transaction in
      for term in terms {
        guard let canonical = try canonical(for: term, in: .query, in: transaction) else {
          continue
        }
        // A canonical term the query already contains would only weight those
        // words twice over.
        let words = Alias.normalize(canonical).split(separator: " ").map(String.init)
        guard !words.isEmpty, !words.allSatisfy(present.contains) else { continue }
        if added.insert(Alias.normalize(canonical)).inserted { additions.append(canonical) }
      }
    }
    return additions.isEmpty ? query : ([query] + additions).joined(separator: " ")
  }

  // MARK: Storage

  private func aliasNode(
    _ normalized: String, in namespace: AliasNamespace, in transaction: Transaction
  ) throws -> NodeID? {
    for node in try transaction.nodeIDs(
      label: Labels.alias, property: Keys.alias, equals: .string(normalized))
    where try transaction.propertyValue(Keys.namespace, ofNode: node)
      == .string(namespace.rawValue)
    {
      return node
    }
    return nil
  }

  private func readAlias(_ node: NodeID, in transaction: Transaction) throws -> Alias {
    func string(_ key: String) throws -> String {
      guard case .string(let value) = try transaction.propertyValue(key, ofNode: node) else {
        return ""
      }
      return value
    }
    return Alias(
      namespace: AliasNamespace(try string(Keys.namespace)),
      alias: try string(Keys.alias),
      canonical: try string(Keys.canonical))
  }
}
