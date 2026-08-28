import Foundation

/// One property rule paired with the property it constrains.
///
/// Produced by ``Rule(_:required:allowsNull:)`` and ``Required(_:allowsNull:)``
/// and collected by ``SchemaBuilder``.
public struct SchemaRule: Sendable, Equatable {
  /// The property name the rule constrains.
  public let name: String

  /// The rule itself.
  public let rule: PropertyRule

  /// Creates a rule for an untyped property name.
  public init(_ name: String, _ rule: PropertyRule) {
    self.name = name
    self.rule = rule
  }
}

/// Collects property rules inside a schema declaration.
@resultBuilder
public enum SchemaBuilder {
  public static func buildExpression(_ rule: SchemaRule) -> [SchemaRule] { [rule] }

  public static func buildExpression(_ rules: [SchemaRule]) -> [SchemaRule] { rules }

  public static func buildBlock(_ components: [SchemaRule]...) -> [SchemaRule] {
    components.flatMap { $0 }
  }

  public static func buildOptional(_ component: [SchemaRule]?) -> [SchemaRule] { component ?? [] }

  public static func buildEither(first component: [SchemaRule]) -> [SchemaRule] { component }

  public static func buildEither(second component: [SchemaRule]) -> [SchemaRule] { component }

  public static func buildArray(_ components: [[SchemaRule]]) -> [SchemaRule] {
    components.flatMap { $0 }
  }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a rule for a typed property, taking its kind from the key.
///
/// ```swift
/// NodeSchema(.person) {
///   Required(Person.name)
///   Rule(Person.age)
/// }
/// ```
public func Rule<Owner, V: ValueRepresentable>(
  _ key: PropertyKey<Owner, V>, required: Bool = false, allowsNull: Bool = false
) -> SchemaRule {
  SchemaRule(
    key.name,
    PropertyRule(kind: V.valueKind, required: required, allowsNull: allowsNull)
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a rule for an untyped property name.
public func Rule(
  _ name: String, _ kind: ValueKind, required: Bool = false, allowsNull: Bool = false
) -> SchemaRule {
  SchemaRule(name, PropertyRule(kind: kind, required: required, allowsNull: allowsNull))
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a required rule for a typed property.
public func Required<Owner, V: ValueRepresentable>(
  _ key: PropertyKey<Owner, V>, allowsNull: Bool = false
) -> SchemaRule {
  Rule(key, required: true, allowsNull: allowsNull)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a required rule for an untyped property name.
public func Required(
  _ name: String, _ kind: ValueKind, allowsNull: Bool = false
) -> SchemaRule {
  Rule(name, kind, required: true, allowsNull: allowsNull)
}

extension NodeSchema {
  /// Creates a node definition from declared rules.
  ///
  /// ```swift
  /// let schema = GraphSchema(
  ///   nodes: [
  ///     NodeSchema(.person, allowsAdditionalProperties: false) {
  ///       Required(Person.name)
  ///       Rule(Person.age)
  ///     }
  ///   ]
  /// )
  /// ```
  public init(
    _ type: NodeType,
    allowsAdditionalProperties: Bool = true,
    @SchemaBuilder _ rules: () -> [SchemaRule]
  ) {
    self.init(
      label: type.rawValue,
      properties: rules().propertyRules,
      allowsAdditionalProperties: allowsAdditionalProperties
    )
  }
}

extension EdgeSchema {
  /// Creates an edge definition from declared rules.
  public init(
    _ type: EdgeType,
    allowsAdditionalProperties: Bool = true,
    @SchemaBuilder _ rules: () -> [SchemaRule]
  ) {
    self.init(
      type: type.rawValue,
      properties: rules().propertyRules,
      allowsAdditionalProperties: allowsAdditionalProperties
    )
  }
}

extension [SchemaRule] {
  /// Returns these rules keyed by property name, later rules winning.
  public var propertyRules: [String: PropertyRule] {
    reduce(into: [:]) { $0[$1.name] = $1.rule }
  }
}
