import Foundation
import LatticeDB

// MARK: - Request

/// Which kinds of record retrieval may return.
public struct RecordKinds: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Derived conclusions.
  public static let assertions = RecordKinds(rawValue: 1 << 0)

  /// Raw records.
  public static let evidence = RecordKinds(rawValue: 1 << 1)

  /// Both.
  public static let all: RecordKinds = [.assertions, .evidence]
}

/// How candidates are found and ranked.
public enum SearchMode: String, Sendable {
  /// BM25 over the full-text indexes. Exact about words.
  case lexical

  /// Nearest neighbors of the query's embedding. Finds paraphrases, and will
  /// return something plausible when nothing relevant exists.
  case vector

  /// Both, fused by reciprocal rank. A record both rankings like outranks one
  /// that either alone puts first.
  case hybrid

  /// Newest first, ignoring the query text entirely.
  case recency

  /// ``hybrid`` when the store has an embedder and the request has a query,
  /// ``lexical`` when there is a query but no embedder, and ``recency`` when
  /// there is no query.
  case automatic
}

/// What to retrieve, and how much of it.
///
/// The defaults retrieve current assertions and evidence visible in a scope,
/// ranked by relevance to a query, with no ceiling. Narrow from there.
public struct RetrievalRequest: Sendable {
  /// Text to rank by, or `nil` to rank by recency.
  public var query: String?

  /// The context to retrieve within. Records outside it are never returned.
  public var scope: Scope

  /// Which kinds of record to return.
  public var kinds: RecordKinds

  /// Slots to restrict assertions to, or `nil` for every slot.
  public var slots: Set<Slot>?

  /// Categories to restrict assertions to, or `nil` for every category.
  public var categories: Set<String>?

  /// Evidence kinds to restrict to, or `nil` for every kind.
  public var evidenceKinds: Set<String>?

  /// The moment to read as of, or `nil` for the present.
  ///
  /// With a date, assertions are those that held then rather than those current
  /// now — the same distinction as
  /// ``MemoryStore/assertions(validAt:in:slot:category:)``.
  public var validAt: Date?

  /// A window on evidence's `occurredAt`, or `nil` for all of time.
  public var occurredIn: Range<Date>?

  /// How candidates are found and ranked.
  public var mode: SearchMode

  /// How many candidates to generate before filtering.
  ///
  /// Filtering happens after ranking, so a scope that excludes most of the store
  /// needs a wider candidate pool to fill a budget.
  public var candidateLimit: Int

  /// The ceiling on what is returned.
  public var budget: Budget

  /// Whether to drop evidence that a returned assertion already cites.
  ///
  /// The conclusion usually says what the raw record said, more briefly. Turn
  /// this off when the raw wording matters — a quote for display, a diff, an
  /// audit.
  public var suppressesCitedEvidence: Bool

  public init(
    query: String? = nil, scope: Scope = .global, kinds: RecordKinds = .all,
    slots: Set<Slot>? = nil, categories: Set<String>? = nil, evidenceKinds: Set<String>? = nil,
    validAt: Date? = nil, occurredIn: Range<Date>? = nil, mode: SearchMode = .automatic,
    candidateLimit: Int = 200, budget: Budget = .unlimited, suppressesCitedEvidence: Bool = true
  ) {
    self.query = query
    self.scope = scope
    self.kinds = kinds
    self.slots = slots
    self.categories = categories
    self.evidenceKinds = evidenceKinds
    self.validAt = validAt
    self.occurredIn = occurredIn
    self.mode = mode
    self.candidateLimit = candidateLimit
    self.budget = budget
    self.suppressesCitedEvidence = suppressesCitedEvidence
  }
}

// MARK: - Result

/// A record returned by retrieval.
public enum RetrievedRecord: Sendable {
  case evidence(Evidence)
  case assertion(Assertion)
}

/// One retrieved record, with why it ranked where it did and what it cost.
public struct RetrievedItem: Sendable {
  /// The record itself.
  public let record: RetrievedRecord

  /// The rank score. Higher is better; the scale depends on the
  /// ``SearchMode`` and is meaningful only for comparing items in one result.
  public let score: Double

  /// What this cost against the request's ``Budget``.
  public let cost: Int

  /// The record's identifier.
  public var id: RecordID {
    switch record {
    case .evidence(let evidence): return evidence.id
    case .assertion(let assertion): return assertion.id
    }
  }

  /// The record's text.
  public var text: String {
    switch record {
    case .evidence(let evidence): return evidence.text
    case .assertion(let assertion): return assertion.text
    }
  }
}

/// A group of retrieved items sharing a heading.
///
/// Assertions are grouped by ``SlotRule/category``, and evidence follows in one
/// group. Use these when assembling a document; use ``RetrievalResult/items``
/// when you only want the ranking.
public struct RetrievalSection: Sendable {
  /// A heading for the group.
  public let title: String

  /// The items in it, in rank order.
  public let items: [RetrievedItem]
}

/// Why a candidate did not survive to the result.
public enum DropReason: String, Sendable, CaseIterable {
  /// The record's scope is not visible from the request's.
  case outOfScope
  /// The assertion did not hold at the requested moment.
  case notValidThen
  /// The evidence occurred outside the requested window.
  case outsideWindow
  /// The record's kind, slot, or category was not asked for.
  case notRequested
  /// A returned assertion already cites this evidence.
  case citedByAssertion
  /// The record was forgotten.
  case forgotten
  /// The budget filled before reaching it.
  case overBudget
}

/// An account of what retrieval did.
///
/// Retrieval that silently returns less than expected is hard to debug: a scope
/// typo and an empty store look identical. The trace distinguishes them by
/// saying how many candidates were generated and where each one went.
public struct RetrievalTrace: Sendable {
  /// The mode actually used, with ``SearchMode/automatic`` already resolved.
  public let mode: SearchMode

  /// How many candidates ranking produced before filtering.
  public let candidates: Int

  /// How many candidates each rule dropped.
  public let dropped: [DropReason: Int]

  /// The total cost of what was returned.
  public let cost: Int

  /// The budget's ceiling, when it had one.
  public let limit: Int?

  /// Conditions worth surfacing, such as a truncated result.
  public let warnings: [String]
}

/// What retrieval returned.
public struct RetrievalResult: Sendable {
  /// Everything returned, in rank order.
  public let items: [RetrievedItem]

  /// The same items, grouped for assembly into a document.
  public let sections: [RetrievalSection]

  /// An account of what was dropped and why.
  public let trace: RetrievalTrace

  /// Whether the budget cut the result short.
  public var wasTruncated: Bool { (trace.dropped[.overBudget] ?? 0) > 0 }

  /// The sections rendered as plain text, one heading and one line per item.
  ///
  /// This is a convenience for the common case, not a format to build on. When
  /// the layout matters, walk ``sections`` and write your own.
  public var rendered: String {
    sections
      .map { section in
        ([section.title] + section.items.map { "- \($0.text)" }).joined(separator: "\n")
      }
      .joined(separator: "\n\n")
  }
}

// MARK: - Pipeline

extension MemoryStore {
  /// Retrieves the records that best answer `request`.
  ///
  /// The pipeline is deterministic in its filtering, whatever the ranking does:
  ///
  /// 1. Generate candidates in the requested ``SearchMode``.
  /// 2. Drop anything outside ``RetrievalRequest/scope``.
  /// 3. Drop assertions that did not hold at ``RetrievalRequest/validAt``, and
  ///    evidence outside ``RetrievalRequest/occurredIn``.
  /// 4. Drop kinds, slots, categories, and evidence kinds that were not asked
  ///    for, and any evidence that has been forgotten.
  /// 5. Drop evidence that a surviving assertion already cites, unless
  ///    ``RetrievalRequest/suppressesCitedEvidence`` is off.
  /// 6. Fill the ``Budget`` in rank order and drop the rest.
  ///
  /// Every drop is counted in ``RetrievalResult/trace``, so a result that is
  /// smaller than expected explains itself.
  public func retrieve(_ request: RetrievalRequest) throws -> RetrievalResult {
    let mode = resolve(request.mode, for: request)
    let ranked = try candidates(for: request, mode: mode)

    var dropped: [DropReason: Int] = [:]
    func drop(_ reason: DropReason) { dropped[reason, default: 0] += 1 }

    var surviving: [(record: RetrievedRecord, score: Double)] = []
    for candidate in ranked {
      switch candidate.record {
      case .assertion(let assertion):
        guard request.kinds.contains(.assertions) else {
          drop(.notRequested)
          continue
        }
        guard assertion.scope.isVisible(in: request.scope) else {
          drop(.outOfScope)
          continue
        }
        if let validAt = request.validAt {
          guard assertion.held(at: validAt) else {
            drop(.notValidThen)
            continue
          }
        } else if assertion.state != .current {
          drop(.notValidThen)
          continue
        }
        if let slots = request.slots, !slots.contains(assertion.slot) {
          drop(.notRequested)
          continue
        }
        if let categories = request.categories {
          guard let category = assertion.category, categories.contains(category) else {
            drop(.notRequested)
            continue
          }
        }
      case .evidence(let evidence):
        guard request.kinds.contains(.evidence) else {
          drop(.notRequested)
          continue
        }
        guard !evidence.isForgotten else {
          drop(.forgotten)
          continue
        }
        guard evidence.scope.isVisible(in: request.scope) else {
          drop(.outOfScope)
          continue
        }
        if let window = request.occurredIn, !window.contains(evidence.occurredAt) {
          drop(.outsideWindow)
          continue
        }
        if let kinds = request.evidenceKinds, !kinds.contains(evidence.kind) {
          drop(.notRequested)
          continue
        }
      }
      surviving.append((candidate.record, candidate.score))
    }

    if request.suppressesCitedEvidence {
      var cited: Set<RecordID> = []
      for entry in surviving {
        if case .assertion(let assertion) = entry.record { cited.formUnion(assertion.evidence) }
      }
      surviving.removeAll { entry in
        guard case .evidence(let evidence) = entry.record, cited.contains(evidence.id) else {
          return false
        }
        drop(.citedByAssertion)
        return true
      }
    }

    var items: [RetrievedItem] = []
    var spent = 0
    var overBudget = 0
    for entry in surviving {
      let text = RetrievedItem(record: entry.record, score: entry.score, cost: 0).text
      let cost = request.budget.measure(text)
      if let limit = request.budget.limit, spent + cost > limit {
        overBudget += 1
        continue
      }
      spent += cost
      items.append(RetrievedItem(record: entry.record, score: entry.score, cost: cost))
    }
    if overBudget > 0 { dropped[.overBudget] = overBudget }

    var warnings: [String] = []
    if overBudget > 0 {
      warnings.append("\(overBudget) record(s) did not fit the budget of \(request.budget.limit!)")
    }
    if ranked.isEmpty, request.query != nil {
      warnings.append("the query matched nothing before filtering")
    }

    return RetrievalResult(
      items: items,
      sections: sections(from: items),
      trace: RetrievalTrace(
        mode: mode, candidates: ranked.count, dropped: dropped, cost: spent,
        limit: request.budget.limit, warnings: warnings))
  }

  private func resolve(_ mode: SearchMode, for request: RetrievalRequest) -> SearchMode {
    guard mode == .automatic else { return mode }
    guard request.query != nil else { return .recency }
    return embedder == nil ? .lexical : .hybrid
  }

  /// Groups items under headings: one per assertion category, then evidence.
  private func sections(from items: [RetrievedItem]) -> [RetrievalSection] {
    var byCategory: [String: [RetrievedItem]] = [:]
    var order: [String] = []
    var evidence: [RetrievedItem] = []
    for item in items {
      switch item.record {
      case .assertion(let assertion):
        let title = assertion.category ?? "Assertions"
        if byCategory[title] == nil { order.append(title) }
        byCategory[title, default: []].append(item)
      case .evidence:
        evidence.append(item)
      }
    }
    var sections = order.map { RetrievalSection(title: $0, items: byCategory[$0] ?? []) }
    if !evidence.isEmpty { sections.append(RetrievalSection(title: "Evidence", items: evidence)) }
    return sections
  }

  // MARK: - Candidate generation

  private struct Candidate {
    var record: RetrievedRecord
    var score: Double
  }

  private func candidates(for request: RetrievalRequest, mode: SearchMode) throws -> [Candidate] {
    guard let query = request.query, mode != .recency else {
      return try recencyOrdered(limit: request.candidateLimit)
    }

    var rankings: [[RecordAddress]] = []
    if mode == .lexical || mode == .hybrid {
      rankings.append(try lexicalRanking(query, limit: request.candidateLimit))
    }
    if mode == .vector || mode == .hybrid {
      rankings.append(try vectorRanking(query, limit: request.candidateLimit))
    }

    let fused = reciprocalRankFusion(rankings).prefix(request.candidateLimit)
    return try database.read { transaction in
      try fused.map { entry in
        Candidate(record: try load(entry.address, in: transaction), score: entry.score)
      }
    }
  }

  /// A candidate before its record is loaded: the node and which label it holds.
  private struct RecordAddress: Hashable {
    var node: NodeID
    var isAssertion: Bool
  }

  private func recencyOrdered(limit: Int) throws -> [Candidate] {
    try database.read { transaction in
      var candidates: [(RetrievedRecord, Date)] = []
      for node in try transaction.nodeIDs(label: Labels.assertion) {
        let assertion = try readAssertion(node, in: transaction)
        candidates.append((.assertion(assertion), assertion.validFrom))
      }
      for node in try transaction.nodeIDs(label: Labels.evidence) {
        let evidence = try readEvidence(node, in: transaction)
        candidates.append((.evidence(evidence), evidence.occurredAt))
      }
      // Newest first, and the timestamp doubles as the score so callers can see
      // what the ordering was based on.
      return
        candidates
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map { Candidate(record: $0.0, score: $0.1.timeIntervalSince1970) }
    }
  }

  private func lexicalRanking(_ query: String, limit: Int) throws -> [RecordAddress] {
    // The full-text index is declared per label, so this is two searches. Their
    // BM25 scores come from different indexes and are not comparable, so the
    // two lists are fused by rank rather than merged by score.
    let assertions = try database.fullTextSearch(
      query, label: Labels.assertion, property: Keys.text, limit: limit
    ).map { RecordAddress(node: $0.node, isAssertion: true) }
    let evidence = try database.fullTextSearch(
      query, label: Labels.evidence, property: Keys.text, limit: limit
    ).map { RecordAddress(node: $0.node, isAssertion: false) }
    return reciprocalRankFusion([assertions, evidence]).map(\.address)
  }

  private func vectorRanking(_ query: String, limit: Int) throws -> [RecordAddress] {
    guard let embedder else { return [] }
    let vector = try embedder.embed(query)
    let matches = try database.vectorSearch(vector, limit: limit)
    return try database.read { transaction in
      // One vector index covers the whole file, so a hit's label says which
      // kind of record it is. Anything else in the database is not ours.
      try matches.compactMap { match in
        let labels = try transaction.labels(of: match.node)
        if labels.contains(Labels.assertion) {
          return RecordAddress(node: match.node, isAssertion: true)
        }
        if labels.contains(Labels.evidence) {
          return RecordAddress(node: match.node, isAssertion: false)
        }
        return nil
      }
    }
  }

  private func load(_ address: RecordAddress, in transaction: Transaction) throws -> RetrievedRecord
  {
    address.isAssertion
      ? .assertion(try readAssertion(address.node, in: transaction))
      : .evidence(try readEvidence(address.node, in: transaction))
  }

  /// Fuses rankings by position rather than by score.
  ///
  /// BM25 scores and vector distances are different quantities on different
  /// scales, so they cannot be added. Reciprocal rank fusion scores each item by
  /// `1 / (k + position)` in every list it appears in and sums those, which
  /// needs nothing from the rankings but their order. An item both rankings
  /// place highly beats one that either alone puts first.
  private func reciprocalRankFusion(
    _ rankings: [[RecordAddress]], k: Double = 60
  ) -> [(address: RecordAddress, score: Double)] {
    var scores: [RecordAddress: Double] = [:]
    for ranking in rankings {
      for (index, address) in ranking.enumerated() {
        scores[address, default: 0] += 1 / (k + Double(index + 1))
      }
    }
    return
      scores
      .sorted { ($0.value, $0.key.node) > ($1.value, $1.key.node) }
      .map { (address: $0.key, score: $0.value) }
  }
}
