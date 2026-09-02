import Foundation

/// The context a record belongs to, as a set of named dimensions.
///
/// Dimensions are yours to choose: `["project": "acme", "environment": "staging"]`
/// and `["tenant": "17", "device": "sensor-4"]` are equally valid. Nothing in
/// this library interprets a dimension name.
///
/// ## Visibility
///
/// A record is visible to a query when **every dimension the record declares
/// appears in the query with the same value** — that is, when the record's scope
/// is a sub-dictionary of the query's.
///
/// ```swift
/// let record = Scope(["project": "acme"])
/// record.isVisible(in: Scope(["project": "acme", "user": "sam"]))  // true
/// record.isVisible(in: Scope(["project": "other"]))                // false
///
/// let narrow = Scope(["project": "acme", "user": "sam"])
/// narrow.isVisible(in: Scope(["project": "acme"]))                 // false
/// ```
///
/// The asymmetry is the point. A broadly-scoped record applies inside any
/// context that contains it, while a record qualified by a dimension the query
/// did not supply stays hidden — a query that does not say *which* user cannot
/// be answered with one user's data. Scope is checked on every read, so widening
/// a query is the only way to reach a narrower record.
public struct Scope: Hashable, Sendable, Codable {
  /// The dimension names and values, such as `["project": "acme"]`.
  public var dimensions: [String: String]

  /// Creates a scope from its dimensions.
  public init(_ dimensions: [String: String] = [:]) {
    self.dimensions = dimensions
  }

  /// The scope that declares no dimensions.
  ///
  /// A record scoped this way is visible to every query, and a query scoped this
  /// way sees only records that are themselves unscoped.
  public static let global = Scope()

  /// Whether a record carrying this scope is visible to a query scoped by
  /// `query`.
  public func isVisible(in query: Scope) -> Bool {
    dimensions.allSatisfy { query.dimensions[$0.key] == $0.value }
  }

  /// Returns this scope with `value` set for `dimension`.
  public func adding(_ dimension: String, _ value: String) -> Scope {
    var copy = self
    copy.dimensions[dimension] = value
    return copy
  }

  /// Whether every dimension of `other` appears here with the same value.
  ///
  /// An extractor may narrow the scope it writes into, never leave it; see
  /// ``MemoryStore/record(_:)``.
  func contains(_ other: Scope) -> Bool {
    other.isVisible(in: self)
  }

  /// The stored form: dimensions sorted and joined, so two equal scopes always
  /// produce the same string and slot supersession can match on it directly.
  var storageKey: String {
    dimensions
      .sorted { $0.key < $1.key }
      .map { "\(escape($0.key))=\(escape($0.value))" }
      .joined(separator: "&")
  }

  /// Rebuilds a scope from ``storageKey``.
  init(storageKey: String) {
    guard !storageKey.isEmpty else {
      self.init()
      return
    }
    var dimensions: [String: String] = [:]
    for pair in storageKey.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      dimensions[unescape(String(parts[0]))] = unescape(String(parts[1]))
    }
    self.init(dimensions)
  }
}

extension Scope: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, String)...) {
    self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

/// Percent-encodes the two characters that structure a ``Scope/storageKey``, so
/// a dimension value containing one cannot forge a second dimension.
private func escape(_ text: String) -> String {
  text.replacingOccurrences(of: "%", with: "%25")
    .replacingOccurrences(of: "=", with: "%3D")
    .replacingOccurrences(of: "&", with: "%26")
}

private func unescape(_ text: String) -> String {
  text.replacingOccurrences(of: "%3D", with: "=")
    .replacingOccurrences(of: "%26", with: "&")
    .replacingOccurrences(of: "%25", with: "%")
}
