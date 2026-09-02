import Foundation
import LatticeDB

/// An assertion an extractor suggests writing.
///
/// A proposal is a suggestion, not a write. Every field is checked against the
/// store's ``MemorySchema`` and against the evidence it claims to come from
/// before anything is stored; see ``MemoryStore/record(_:)``.
public struct AssertionProposal: Sendable, Equatable {
  /// What the assertion is about. Must be declared in the schema.
  public var slot: Slot

  /// The asserted value, which must match the slot rule's kind.
  public var value: Value

  /// A human-readable rendering. Defaults to the value's own text.
  public var text: String

  /// The scope to write into, or `nil` to use the evidence's own scope.
  ///
  /// A non-`nil` scope may add dimensions to the evidence's, never drop or
  /// change one.
  public var scope: Scope?

  /// The span of evidence text this was read from.
  ///
  /// It must appear verbatim in the evidence, and is required when the slot rule
  /// says so.
  public var quote: String?

  /// When this became true, or `nil` for the evidence's `occurredAt`.
  public var validFrom: Date?

  /// How much the extractor trusts this, from 0 through 1.
  public var confidence: Double

  public init(
    slot: Slot, value: Value, text: String? = nil, scope: Scope? = nil, quote: String? = nil,
    validFrom: Date? = nil, confidence: Double = 1
  ) {
    self.slot = slot
    self.value = value
    self.text = text ?? Self.describe(value)
    self.scope = scope
    self.quote = quote
    self.validFrom = validFrom
    self.confidence = confidence
  }

  static func describe(_ value: Value) -> String {
    switch value {
    case .null: return ""
    case .bool(let value): return String(value)
    case .integer(let value): return String(value)
    case .double(let value): return String(value)
    case .string(let value): return value
    }
  }
}

/// Something that reads evidence and suggests assertions to derive from it.
///
/// Extractors are deliberately powerless. One may propose anything; the store
/// then rejects every proposal that names an undeclared slot, carries the wrong
/// value kind, quotes text the evidence does not contain, or reaches outside the
/// evidence's scope. That division is what makes an untrusted extractor — a
/// heuristic you have not audited, or a remote model — safe to run against a
/// store whose contents you rely on.
///
/// An extractor that throws does not fail the ingest: the store records the
/// failure as a ``RejectionReason/extractorFailed(_:)`` and keeps the evidence
/// and the other extractors' output.
public protocol Extractor: Sendable {
  /// Returns the assertions `evidence` suggests, or none.
  func extract(from evidence: Evidence) throws -> [AssertionProposal]
}

/// Carries a compiled pattern across concurrency domains.
///
/// `Regex` is not `Sendable`, although matching against one only reads it. A
/// pattern built from a literal or a string holds no mutable state, so the
/// unchecked conformance is sound. A `CustomConsumingRegexComponent` that does
/// hold mutable state would not be, and is the caller's responsibility.
private struct PatternBox: @unchecked Sendable {
  let regex: Regex<AnyRegexOutput>
}

/// An extractor that reads values out of evidence text with regular expressions.
///
/// This is the deterministic default: it needs no network, no model, and no
/// configuration beyond its patterns, and it produces the same output for the
/// same input forever. That makes it usable as the whole extraction layer for
/// well-structured text, and as a reproducible baseline to compare a fancier
/// extractor against.
///
/// ```swift
/// let extractor = PatternExtractor([
///   .init(
///     slot: "package.manager",
///     pattern: #/\b(?:use|using|switched to)\s+(npm|pnpm|yarn)\b/#.ignoresCase()
///   )
/// ])
/// ```
///
/// The first capture group is the value; with no capture group, the whole match
/// is. The matched text becomes the proposal's quote, so a rule's
/// ``SlotRule/requiresQuote`` is always satisfied and the citation is verbatim by
/// construction.
public struct PatternExtractor: Extractor {
  /// One pattern and the slot it fills.
  public struct Rule: Sendable {
    /// The slot to propose.
    public var slot: Slot

    /// The pattern to search the evidence text for.
    public var pattern: Regex<AnyRegexOutput> { box.regex }

    private let box: PatternBox

    /// How much to trust a match.
    public var confidence: Double

    /// Kinds of evidence this rule applies to, or `nil` for all of them.
    public var evidenceKinds: Set<String>?

    /// Turns the captured text into the asserted value.
    ///
    /// Defaults to storing it as a string. Supply a transform to store a number,
    /// normalize case, or map an alias onto a canonical value.
    public var transform: @Sendable (String) -> Value?

    public init(
      slot: Slot, pattern: some RegexComponent, confidence: Double = 1,
      evidenceKinds: Set<String>? = nil,
      transform: @escaping @Sendable (String) -> Value? = { .string($0) }
    ) {
      self.slot = slot
      self.box = PatternBox(regex: Regex(pattern.regex))
      self.confidence = confidence
      self.evidenceKinds = evidenceKinds
      self.transform = transform
    }
  }

  /// The rules, applied in order.
  public var rules: [Rule]

  /// Whether a rule proposes only its last match rather than every match.
  ///
  /// The default suits single-valued slots, where the last statement in a
  /// document is usually the operative one. Set it to `false` for a
  /// ``Cardinality/multiple`` slot that should collect every mention.
  public var lastMatchOnly: Bool

  public init(_ rules: [Rule], lastMatchOnly: Bool = true) {
    self.rules = rules
    self.lastMatchOnly = lastMatchOnly
  }

  public func extract(from evidence: Evidence) throws -> [AssertionProposal] {
    var proposals: [AssertionProposal] = []
    for rule in rules {
      if let kinds = rule.evidenceKinds, !kinds.contains(evidence.kind) { continue }
      let matches = evidence.text.matches(of: rule.pattern)
      for match in lastMatchOnly ? Array(matches.suffix(1)) : matches {
        let captured = match.output.count > 1 ? match.output[1].substring : nil
        let text = String(captured ?? evidence.text[match.range])
        guard let value = rule.transform(text) else { continue }
        proposals.append(
          AssertionProposal(
            slot: rule.slot, value: value, quote: String(evidence.text[match.range]),
            confidence: rule.confidence))
      }
    }
    return proposals
  }
}
