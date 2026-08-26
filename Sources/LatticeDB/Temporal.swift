import Foundation

/// An invalid ``TemporalValidity`` interval.
public enum TemporalValidityError: Error, Sendable, Equatable {
  /// The exclusive end precedes the inclusive start.
  case endBeforeStart
}

/// An invalid identifier supplied to ``TemporalAsOf``.
public enum TemporalQueryError: Error, Sendable, Equatable {
  /// A Cypher identifier was empty or contained unsupported characters.
  case invalidIdentifier(String)
}

/// An opt-in application-level valid-time interval.
///
/// The interval is stored as epoch-millisecond properties and qualifies current
/// graph data. It does not select a historical native database snapshot.
public struct TemporalValidity: Sendable, Equatable {
  /// The inclusive start of the validity interval.
  public let validFrom: Date

  /// The optional exclusive end of the validity interval.
  public let validTo: Date?

  /// Creates a valid-time interval.
  ///
  /// - Parameters:
  ///   - validFrom: The inclusive interval start.
  ///   - validTo: The optional exclusive interval end.
  public init(validFrom: Date, validTo: Date? = nil) throws {
    guard validTo.map({ $0 >= validFrom }) ?? true else {
      throw TemporalValidityError.endBeforeStart
    }
    self.validFrom = validFrom
    self.validTo = validTo
  }

  /// Returns whether `date` lies within this interval.
  public func contains(_ date: Date) -> Bool {
    date >= validFrom && validTo.map { date < $0 } != false
  }

  /// Returns epoch-millisecond properties representing this interval.
  ///
  /// - Parameters:
  ///   - fromKey: The property key for the inclusive start.
  ///   - toKey: The property key for the exclusive end.
  public func propertyValues(
    fromKey: String = "validFrom",
    toKey: String = "validTo"
  ) -> [String: Value] {
    var properties: [String: Value] = [fromKey: .integer(epochMilliseconds(validFrom))]
    properties[toKey] = validTo.map { .integer(epochMilliseconds($0)) } ?? .null
    return properties
  }
}

/// A native Cypher predicate and parameter set for valid-time filtering.
///
/// This filters current records by their application-level validity interval;
/// it is not a historical snapshot query.
public struct TemporalAsOf: Sendable, Equatable {
  /// The instant used to qualify records.
  public let date: Date

  /// The property key storing an interval's inclusive start.
  public let fromKey: String

  /// The property key storing an interval's exclusive end.
  public let toKey: String

  /// The Cypher parameter name used for ``parameters``.
  public let parameter: String

  /// Creates a valid-time query qualifier.
  ///
  /// All keys and the parameter name must be simple Cypher identifiers.
  public init(
    date: Date,
    fromKey: String = "validFrom",
    toKey: String = "validTo",
    parameter: String = "asOf"
  ) throws {
    for identifier in [fromKey, toKey, parameter] { try validateCypherIdentifier(identifier) }
    self.date = date
    self.fromKey = fromKey
    self.toKey = toKey
    self.parameter = parameter
  }

  /// Returns the bound query parameter for this qualifier.
  public var parameters: [String: Value] {
    [parameter: .integer(epochMilliseconds(date))]
  }

  /// Returns a Cypher predicate for records valid at ``date``.
  ///
  /// - Parameter variable: The Cypher variable referring to a node or edge.
  public func predicate(for variable: String) throws -> String {
    try validateCypherIdentifier(variable)
    return
      "\(variable).\(fromKey) <= $\(parameter) AND (\(variable).\(toKey) IS NULL OR \(variable).\(toKey) > $\(parameter))"
  }
}

extension Transaction {
  /// Stores `validity` on a node using the supplied property keys.
  public func setTemporalValidity(
    _ validity: TemporalValidity,
    onNode node: NodeID,
    fromKey: String = "validFrom",
    toKey: String = "validTo"
  ) throws {
    try setProperties(validity.propertyValues(fromKey: fromKey, toKey: toKey), onNode: node)
  }

  /// Stores `validity` on an edge using the supplied property keys.
  public func setTemporalValidity(
    _ validity: TemporalValidity,
    onEdge edge: EdgeID,
    fromKey: String = "validFrom",
    toKey: String = "validTo"
  ) throws {
    try setProperties(validity.propertyValues(fromKey: fromKey, toKey: toKey), onEdge: edge)
  }
}

private func epochMilliseconds(_ date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func validateCypherIdentifier(_ identifier: String) throws {
  guard isSimpleIdentifier(identifier) else {
    throw TemporalQueryError.invalidIdentifier(identifier)
  }
}
