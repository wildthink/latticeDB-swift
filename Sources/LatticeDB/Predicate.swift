import Foundation

/// A condition on one graph variable, rendered into a native `WHERE` clause.
///
/// Predicates are values: build them with the comparison operators on
/// ``PropertyKey``, combine them with `&&`, `||`, and `!`, and render them
/// against a variable. Every literal becomes a bound parameter, never text.
///
/// ```swift
/// let predicate = Person.age >= 21 && Person.name.hasPrefix("A")
/// predicate.render(variable: "p").text
/// // (p.age >= $p0 AND p.name STARTS WITH $p1)
/// ```
public struct Predicate: Sendable {
  /// How a property is compared with a value.
  public enum Comparison: String, Sendable {
    case equal = "="
    case notEqual = "<>"
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
  }

  /// How a string property is matched.
  public enum StringMatch: String, Sendable {
    case hasPrefix = "STARTS WITH"
    case hasSuffix = "ENDS WITH"
    case contains = "CONTAINS"
  }

  indirect enum Term: Sendable {
    case comparison(property: String, Comparison, Value)
    case isNull(property: String, Bool)
    case inList(property: String, [Value])
    case stringMatch(property: String, StringMatch, String)
    case and(Predicate, Predicate)
    case or(Predicate, Predicate)
    case not(Predicate)
    case temporal(TemporalAsOf)
  }

  let term: Term

  init(_ term: Term) { self.term = term }

  /// Renders this predicate as a Cypher fragment for `variable`.
  ///
  /// An invalid variable or property name is captured in the returned fragment
  /// and raised when the query it belongs to runs.
  public func render(variable: String) -> Cypher {
    switch term {
    case .comparison(let property, let comparison, let value):
      return "\(identifier: variable).\(identifier: property) \(raw: comparison.rawValue) \(value)"
    case .isNull(let property, let isNull):
      let test = isNull ? "IS NULL" : "IS NOT NULL"
      return "\(identifier: variable).\(identifier: property) \(raw: test)"
    case .inList(let property, let values):
      var list: Cypher = "\(identifier: variable).\(identifier: property) IN ["
      for (index, value) in values.enumerated() {
        list = index == 0 ? "\(list)\(value)" : "\(list), \(value)"
      }
      return "\(list)]"
    case .stringMatch(let property, let match, let value):
      return
        "\(identifier: variable).\(identifier: property) \(raw: match.rawValue) \(value)"
    case .and(let lhs, let rhs):
      return "(\(lhs.render(variable: variable)) AND \(rhs.render(variable: variable)))"
    case .or(let lhs, let rhs):
      return "(\(lhs.render(variable: variable)) OR \(rhs.render(variable: variable)))"
    case .not(let inner):
      return "NOT (\(inner.render(variable: variable)))"
    case .temporal(let asOf):
      return temporalPredicate(asOf, variable: variable)
    }
  }

  private func temporalPredicate(_ asOf: TemporalAsOf, variable: String) -> Cypher {
    let instant = Value.integer(Int64((asOf.date.timeIntervalSince1970 * 1_000).rounded()))
    let from: Cypher = "\(identifier: variable).\(identifier: asOf.fromKey) <= \(instant)"
    let to: Cypher =
      "(\(identifier: variable).\(identifier: asOf.toKey) IS NULL OR "
      + "\(identifier: variable).\(identifier: asOf.toKey) > \(instant))"
    return "(\(from) AND \(to))"
  }
}

extension Cypher {
  /// Concatenates two fragments, renumbering the right-hand parameters.
  public static func + (lhs: Cypher, rhs: Cypher) -> Cypher {
    "\(lhs)\(rhs)"
  }
}

extension PropertyKey {
  /// A predicate matching rows where this property is unset or null.
  public var isNull: Predicate { Predicate(.isNull(property: name, true)) }

  /// A predicate matching rows where this property has a value.
  public var isNotNull: Predicate { Predicate(.isNull(property: name, false)) }

  /// A predicate matching rows where this property equals one of `values`.
  public func `in`(_ values: [Value]) -> Predicate {
    Predicate(.inList(property: name, values.map(\.latticeValue)))
  }
}

extension PropertyKey where Value == String {
  /// A predicate matching rows whose value starts with `prefix`.
  public func hasPrefix(_ prefix: String) -> Predicate {
    Predicate(.stringMatch(property: name, .hasPrefix, prefix))
  }

  /// A predicate matching rows whose value ends with `suffix`.
  public func hasSuffix(_ suffix: String) -> Predicate {
    Predicate(.stringMatch(property: name, .hasSuffix, suffix))
  }

  /// A predicate matching rows whose value contains `substring`.
  public func contains(_ substring: String) -> Predicate {
    Predicate(.stringMatch(property: name, .contains, substring))
  }
}

/// Returns a predicate matching rows where the property equals `value`.
public func == <Owner, V: ValueRepresentable>(key: PropertyKey<Owner, V>, value: V) -> Predicate {
  Predicate(.comparison(property: key.name, .equal, value.latticeValue))
}

/// Returns a predicate matching rows where the property differs from `value`.
public func != <Owner, V: ValueRepresentable>(key: PropertyKey<Owner, V>, value: V) -> Predicate {
  Predicate(.comparison(property: key.name, .notEqual, value.latticeValue))
}

/// Returns a predicate matching rows where the property is less than `value`.
public func < <Owner, V: ValueRepresentable>(key: PropertyKey<Owner, V>, value: V) -> Predicate {
  Predicate(.comparison(property: key.name, .lessThan, value.latticeValue))
}

/// Returns a predicate matching rows where the property is at most `value`.
public func <= <Owner, V: ValueRepresentable>(key: PropertyKey<Owner, V>, value: V) -> Predicate {
  Predicate(.comparison(property: key.name, .lessThanOrEqual, value.latticeValue))
}

/// Returns a predicate matching rows where the property is greater than `value`.
public func > <Owner, V: ValueRepresentable>(key: PropertyKey<Owner, V>, value: V) -> Predicate {
  Predicate(.comparison(property: key.name, .greaterThan, value.latticeValue))
}

/// Returns a predicate matching rows where the property is at least `value`.
public func >= <Owner, V: ValueRepresentable>(key: PropertyKey<Owner, V>, value: V) -> Predicate {
  Predicate(.comparison(property: key.name, .greaterThanOrEqual, value.latticeValue))
}

/// Returns a predicate satisfied when both predicates are.
public func && (lhs: Predicate, rhs: Predicate) -> Predicate {
  Predicate(.and(lhs, rhs))
}

/// Returns a predicate satisfied when either predicate is.
public func || (lhs: Predicate, rhs: Predicate) -> Predicate {
  Predicate(.or(lhs, rhs))
}

/// Returns a predicate satisfied when `predicate` is not.
public prefix func ! (predicate: Predicate) -> Predicate {
  Predicate(.not(predicate))
}
