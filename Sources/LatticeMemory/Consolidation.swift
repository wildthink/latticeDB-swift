import Foundation
import LatticeDB

/// Something that reads a body of evidence and proposes conclusions drawn from
/// all of it.
///
/// A ``Extractor`` looks at one record at a time; a consolidator looks at many
/// and says what they add up to. The output is the same ``AssertionProposal``,
/// held to the same schema, and the resulting assertion cites **every** record
/// it was given — so forgetting one weakens it and forgetting all of them
/// retracts it, with no extra bookkeeping.
///
/// Consolidation is where a summarizing model would plug in. It is also where a
/// counter, a statistical roll-up, or a rule over structured records plugs in;
/// nothing about the contract assumes prose.
public protocol Consolidator: Sendable {
  /// Returns the conclusions `evidence` supports, or none.
  func consolidate(_ evidence: [Evidence]) throws -> [AssertionProposal]
}

/// Which records to consolidate.
///
/// The selectors match ``ForgetRequest``'s, and select identically — the same
/// scope rule, the same treatment of tombstones — so what you preview before
/// forgetting is what you would have consolidated.
public struct ConsolidationRequest: Sendable {
  /// Evidence to consolidate by identifier.
  public var identifiers: [RecordID]

  /// Consolidate evidence whose text matches this full-text query.
  public var query: String?

  /// Consolidate evidence in exactly this scope, matched exactly rather than by
  /// visibility.
  public var scope: Scope?

  /// Consolidate only these evidence kinds.
  public var evidenceKinds: Set<String>?

  /// Consolidate only evidence that occurred in this window.
  public var occurredIn: Range<Date>?

  /// The most records one call may read.
  public var limit: Int

  public init(
    identifiers: [RecordID] = [], query: String? = nil, scope: Scope? = nil,
    evidenceKinds: Set<String>? = nil, occurredIn: Range<Date>? = nil, limit: Int = 1_000
  ) {
    self.identifiers = identifiers
    self.query = query
    self.scope = scope
    self.evidenceKinds = evidenceKinds
    self.occurredIn = occurredIn
    self.limit = limit
  }

  /// Consolidates specific records.
  public static func identifiers(_ identifiers: [RecordID]) -> ConsolidationRequest {
    ConsolidationRequest(identifiers: identifiers)
  }

  /// Consolidates everything matching a set of filters.
  public static func matching(
    query: String? = nil, scope: Scope? = nil, kinds: Set<String>? = nil,
    occurredIn: Range<Date>? = nil, limit: Int = 1_000
  ) -> ConsolidationRequest {
    ConsolidationRequest(
      query: query, scope: scope, evidenceKinds: kinds, occurredIn: occurredIn, limit: limit)
  }
}

/// What consolidation did.
public struct ConsolidationResult: Sendable {
  /// The records that were read.
  public let consolidated: [RecordID]

  /// The assertions written, each citing all of them.
  public let asserted: [Assertion]

  /// Proposals refused by the schema, with the reason for each.
  public let rejected: [Rejection]

  /// Whether ``ConsolidationRequest/limit`` cut the selection short.
  public let wasTruncated: Bool
}

extension MemoryStore {
  /// Reads the selected evidence, runs `consolidator` over all of it at once,
  /// and writes whatever survives validation.
  ///
  /// The proposals are validated exactly as an extractor's are: declared slot,
  /// declared value kind, permitted value, faithful quote, contained scope. A
  /// consolidator is no more trusted than anything else that proposes.
  ///
  /// Selecting nothing writes nothing and is not an error — a scheduled
  /// consolidation with no new records to fold in should be quiet, not noisy.
  ///
  /// - Note: A conclusion drawn from records in different scopes is written to
  ///   the narrowest scope covering all of them — every dimension any source
  ///   declares. When two sources disagree about a dimension no such scope
  ///   exists, and the proposal fails
  ///   ``RejectionReason/scopeEscapesEvidence(proposed:evidence:)`` rather than
  ///   being written somewhere it does not belong.
  @discardableResult
  public func consolidate(
    _ request: ConsolidationRequest, using consolidator: any Consolidator
  ) throws -> ConsolidationResult {
    let selection = try database.read { transaction in
      try selectEvidence(
        identifiers: request.identifiers, query: request.query, scope: request.scope,
        kinds: request.evidenceKinds, occurredIn: request.occurredIn, limit: request.limit,
        in: transaction)
    }
    guard !selection.evidence.isEmpty else {
      return ConsolidationResult(
        consolidated: [], asserted: [], rejected: [], wasTruncated: selection.wasTruncated)
    }

    var proposals: [AssertionProposal] = []
    var rejected: [Rejection] = []
    do {
      proposals = try consolidator.consolidate(selection.evidence)
    } catch {
      rejected.append(
        Rejection(
          proposal: AssertionProposal(slot: "", value: .null),
          reason: .extractorFailed(String(describing: error))))
    }

    let now = clock()
    let vectors = try embed(proposals.map(\.text))

    var asserted: [Assertion] = []
    try database.write { transaction in
      var nodes: [NodeID] = []
      for evidence in selection.evidence {
        guard let node = try locate(evidence.id, label: Labels.evidence, in: transaction) else {
          throw MemoryError.unknownRecord(evidence.id)
        }
        nodes.append(node)
      }
      for proposal in proposals {
        switch validate(proposal, against: selection.evidence) {
        case .failure(let reason):
          rejected.append(Rejection(proposal: proposal, reason: reason))
        case .success(let checked):
          let outcome = try commit(
            checked, from: selection.evidence, evidenceNodes: nodes, now: now, vectors: vectors,
            in: transaction)
          if let assertion = outcome.assertion { asserted.append(assertion) }
        }
      }
    }

    return ConsolidationResult(
      consolidated: selection.evidence.map(\.id), asserted: asserted, rejected: rejected,
      wasTruncated: selection.wasTruncated)
  }
}

/// A consolidator that joins the selected records into one bounded digest.
///
/// It summarizes nothing — it concatenates, oldest first, and truncates. That is
/// deliberate: it is deterministic, needs no model, and produces the same digest
/// for the same records forever, which makes it usable in tests and as the
/// baseline a real summarizer has to beat. Do not present its output as a
/// summary.
public struct DigestConsolidator: Consolidator {
  /// The slot the digest is written to. Declare it in the schema with a
  /// `string` value kind.
  public var slot: Slot

  /// The greatest number of characters the digest may run to.
  public var maximumLength: Int

  /// What goes between records.
  public var separator: String

  public init(slot: Slot, maximumLength: Int = 2_000, separator: String = " — ") {
    self.slot = slot
    self.maximumLength = maximumLength
    self.separator = separator
  }

  public func consolidate(_ evidence: [Evidence]) throws -> [AssertionProposal] {
    let ordered = evidence.sorted { $0.occurredAt < $1.occurredAt }
    var digest = ""
    for record in ordered where !record.text.isEmpty {
      let piece = digest.isEmpty ? record.text : separator + record.text
      guard digest.count + piece.count <= maximumLength else { break }
      digest += piece
    }
    guard !digest.isEmpty else { return [] }
    return [
      AssertionProposal(
        slot: slot, value: .string(digest), text: digest,
        validFrom: ordered.last?.occurredAt)
    ]
  }
}
