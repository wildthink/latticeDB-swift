import Foundation
import LatticeDB

/// The name of one thing an assertion can say, such as `package.manager` or
/// `sensor.calibration`.
///
/// A slot is the unit supersession works on: within one ``Scope``, a
/// single-valued slot holds exactly one current assertion at a time.
public struct Slot: RawRepresentable, Hashable, Sendable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  public var description: String { rawValue }
}

/// How many assertions a slot holds at once within one scope.
public enum Cardinality: String, Sendable, Codable {
  /// One current assertion. Writing a new one supersedes the old, which stays
  /// readable as history.
  case single

  /// Any number of current assertions, distinguished by value. Writing a value
  /// that is already current is a no-op rather than a duplicate.
  case multiple
}

/// What a slot may hold, and how it behaves when written.
public struct SlotRule: Sendable, Equatable {
  /// How many assertions this slot holds at once within one scope.
  public var cardinality: Cardinality

  /// The scalar kind an assertion's value must have.
  public var kind: ValueKind

  /// An optional grouping label, returned on every assertion and available as a
  /// read filter.
  ///
  /// This replaces a fixed taxonomy: use it for whatever division your domain
  /// has — `"preference"` and `"procedure"`, or `"calibration"` and `"reading"`,
  /// or nothing at all.
  public var category: String?

  /// Values the slot accepts, or `nil` to accept any value of the right kind.
  ///
  /// An extractor proposing a value outside this set is rejected, which is the
  /// cheapest guard against a misconfigured pattern writing nonsense.
  public var allowedValues: Set<String>?

  /// Whether an assertion must quote the evidence text that justifies it.
  ///
  /// When `true`, a proposal without a quote, or with a quote that does not
  /// appear verbatim in its evidence, is rejected.
  public var requiresQuote: Bool

  public init(
    cardinality: Cardinality = .single, kind: ValueKind = .string, category: String? = nil,
    allowedValues: Set<String>? = nil, requiresQuote: Bool = false
  ) {
    self.cardinality = cardinality
    self.kind = kind
    self.category = category
    self.allowedValues = allowedValues
    self.requiresQuote = requiresQuote
  }
}

/// The set of slots a store accepts, and the rules each one is held to.
///
/// The schema is the whole of the trust boundary. An ``Extractor`` proposes
/// assertions and a ``MemoryStore`` checks every proposal against this schema
/// before anything is written, so an extractor — a regular expression, a
/// heuristic, a remote model — can only ever produce values the schema already
/// permits. Nothing writes an undeclared slot.
public struct MemorySchema: Sendable, Equatable {
  /// The declared slots.
  public private(set) var slots: [Slot: SlotRule]

  /// Creates a schema from slot rules.
  public init(slots: [Slot: SlotRule] = [:]) {
    self.slots = slots
  }

  /// Returns the rule for `slot`, or `nil` when it is undeclared.
  public func rule(for slot: Slot) -> SlotRule? { slots[slot] }

  /// Declares `slot`, replacing any existing rule for it.
  public mutating func declare(_ slot: Slot, _ rule: SlotRule) {
    slots[slot] = rule
  }

  /// Returns a copy of this schema with `slot` declared.
  public func declaring(_ slot: Slot, _ rule: SlotRule) -> MemorySchema {
    var copy = self
    copy.declare(slot, rule)
    return copy
  }

  /// The declared slots in `category`.
  public func slots(inCategory category: String) -> [Slot] {
    slots.filter { $0.value.category == category }.keys.sorted { $0.rawValue < $1.rawValue }
  }
}

extension MemorySchema: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (Slot, SlotRule)...) {
    self.init(slots: Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
