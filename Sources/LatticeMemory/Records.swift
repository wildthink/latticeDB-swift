import Foundation
import LatticeDB

/// A raw record, stored exactly as it arrived.
///
/// Evidence is never rewritten. Everything derived from it points back at it, so
/// any stored conclusion can be traced to the text that justifies it — and, when
/// that text is forgotten, the conclusions built on it can be found and dropped
/// with it.
public struct Evidence: Sendable, Equatable, Identifiable {
  /// The stable identifier assigned when this was recorded.
  public let id: RecordID

  /// A caller-defined kind, such as `message`, `commit`, or `reading`.
  ///
  /// Nothing in this library interprets it; it is a filter and a label.
  public var kind: String

  /// The content, which is what full-text search indexes and what a quote must
  /// appear in.
  public var text: String

  /// The context this record belongs to.
  public var scope: Scope

  /// When the underlying event happened.
  ///
  /// This drives valid time on everything derived from it, so a backfilled
  /// record supersedes correctly rather than by arrival order.
  public var occurredAt: Date

  /// When this record entered the store.
  public var recordedAt: Date

  /// Caller-supplied fields, stored alongside and returned unchanged.
  public var metadata: [String: Value]

  /// Whether this record has been forgotten.
  ///
  /// A tombstone keeps its identifier, kind, and timestamps and loses its text
  /// and metadata, so a reference to it resolves to "this was forgotten" rather
  /// than to nothing at all. Retrieval never returns one. See
  /// ``MemoryStore/forget(_:)``.
  public var isForgotten: Bool

  public init(
    id: RecordID, kind: String, text: String, scope: Scope, occurredAt: Date, recordedAt: Date,
    metadata: [String: Value] = [:], isForgotten: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.scope = scope
    self.occurredAt = occurredAt
    self.recordedAt = recordedAt
    self.metadata = metadata
    self.isForgotten = isForgotten
  }
}

/// A record to store, before the store assigns it an identity.
public struct EvidenceDraft: Sendable, Equatable {
  /// A caller-defined kind, such as `message`, `commit`, or `reading`.
  public var kind: String

  /// The content to store and index.
  public var text: String

  /// The context this record belongs to.
  public var scope: Scope

  /// When the underlying event happened, or `nil` for the time of recording.
  public var occurredAt: Date?

  /// Caller-supplied fields to store alongside.
  public var metadata: [String: Value]

  /// An identifier to use instead of a generated one.
  ///
  /// Supply one when an upstream system already has a stable identifier for this
  /// record; recording the same identifier twice throws
  /// ``MemoryError/duplicateIdentifier(_:)`` rather than storing it twice, which
  /// makes replaying a source safe.
  public var id: RecordID?

  public init(
    kind: String = "message", text: String, scope: Scope = .global, occurredAt: Date? = nil,
    metadata: [String: Value] = [:], id: RecordID? = nil
  ) {
    self.kind = kind
    self.text = text
    self.scope = scope
    self.occurredAt = occurredAt
    self.metadata = metadata
    self.id = id
  }
}

/// Whether an assertion is the current answer, an earlier one, or withdrawn.
public enum AssertionState: String, Sendable, Codable {
  /// The current answer for its slot and scope.
  case current

  /// Replaced by a later assertion. It remains readable, and remains true of the
  /// interval between its ``Assertion/validFrom`` and ``Assertion/validTo``.
  case superseded

  /// Withdrawn without a replacement, because a caller retracted it directly or
  /// because every piece of evidence behind it was forgotten.
  case retracted
}

/// Something the store holds to be true of a slot, within a scope, over an
/// interval of time.
///
/// An assertion is derived: it always names the evidence it came from. Writing a
/// new value for a single-valued slot does not overwrite the old one — the old
/// one becomes ``AssertionState/superseded`` and keeps the interval it was true
/// for, so "what did we believe last March" stays answerable.
public struct Assertion: Sendable, Equatable, Identifiable {
  /// The stable identifier assigned when this was written.
  public let id: RecordID

  /// What this assertion is about.
  public var slot: Slot

  /// The asserted value, of the kind the slot's ``SlotRule`` declares.
  public var value: Value

  /// A human-readable rendering, for display and for full-text search.
  public var text: String

  /// The context this assertion applies to.
  public var scope: Scope

  /// Whether this is the current answer, an earlier one, or withdrawn.
  public var state: AssertionState

  /// When this became true.
  public var validFrom: Date

  /// When this stopped being true, or `nil` while it still holds.
  public var validTo: Date?

  /// The evidence records that justify this, in the order they were supplied.
  public var evidence: [RecordID]

  /// The span of evidence text this was read from, when one was given.
  public var quote: String?

  /// How much the extractor trusts this, from 0 through 1.
  ///
  /// Nothing in the store filters on confidence; it is recorded so a reader can.
  public var confidence: Double

  /// The category of the slot's rule at the time this was written.
  public var category: String?

  public init(
    id: RecordID, slot: Slot, value: Value, text: String, scope: Scope, state: AssertionState,
    validFrom: Date, validTo: Date? = nil, evidence: [RecordID], quote: String? = nil,
    confidence: Double = 1, category: String? = nil
  ) {
    self.id = id
    self.slot = slot
    self.value = value
    self.text = text
    self.scope = scope
    self.state = state
    self.validFrom = validFrom
    self.validTo = validTo
    self.evidence = evidence
    self.quote = quote
    self.confidence = confidence
    self.category = category
  }

  /// Whether this assertion held at `date`.
  ///
  /// The interval is half-open: it includes ``validFrom`` and excludes
  /// ``validTo``, so a value replaced at an instant is never true twice at that
  /// instant.
  public func held(at date: Date) -> Bool {
    guard state != .retracted, date >= validFrom else { return false }
    guard let validTo else { return true }
    return date < validTo
  }
}
