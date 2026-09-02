import Foundation
import LatticeDB

/// A failure raised by the store rather than by the native engine.
public enum MemoryError: Error, Sendable, Equatable {
  /// An identifier already in the store was supplied again.
  case duplicateIdentifier(RecordID)

  /// An operation named a record the store does not hold.
  case unknownRecord(RecordID)

  /// A record was read back with a property missing or of the wrong kind, which
  /// means the graph was written by something other than this library.
  case malformedRecord(RecordID, String)
}

/// Why a proposed assertion was refused.
///
/// Rejections are returned rather than thrown: one bad proposal should not
/// discard the evidence it came from, nor the proposals beside it. Read them
/// from ``IngestResult/rejected``.
public enum RejectionReason: Error, Sendable, Equatable {
  /// The slot is not declared in the store's ``MemorySchema``.
  case undeclaredSlot(Slot)

  /// The value's kind is not the one the slot's rule declares.
  case wrongValueKind(expected: ValueKind, actual: ValueKind)

  /// The value is not in the rule's `allowedValues`.
  case disallowedValue(String)

  /// The rule requires a quote and the proposal carried none.
  case missingQuote

  /// The quote does not appear in the text of the evidence it claims to come
  /// from. This is what stops an extractor from inventing a citation.
  case unfaithfulQuote(String)

  /// The proposal's scope drops or changes a dimension of its evidence's scope.
  /// An extractor may narrow the scope it writes into, never leave it.
  case scopeEscapesEvidence(proposed: Scope, evidence: Scope)

  /// Confidence was outside 0 through 1.
  case invalidConfidence(Double)

  /// The extractor threw. The message is its error, as text.
  case extractorFailed(String)
}

/// A proposal that was refused, with the reason.
public struct Rejection: Error, Sendable, Equatable {
  /// The refused proposal.
  public let proposal: AssertionProposal

  /// Why it was refused.
  public let reason: RejectionReason

  public init(proposal: AssertionProposal, reason: RejectionReason) {
    self.proposal = proposal
    self.reason = reason
  }
}
