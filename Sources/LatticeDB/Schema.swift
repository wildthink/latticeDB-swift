/// The expected scalar kind of a property in an advisory schema.
public enum ValueKind: String, Sendable, Equatable {
  /// A null value.
  case null
  /// A Boolean value.
  case bool
  /// A signed 64-bit integer.
  case integer
  /// A double-precision floating-point number.
  case double
  /// A UTF-8 string.
  case string

  init(_ value: Value) {
    switch value {
    case .null: self = .null
    case .bool: self = .bool
    case .integer: self = .integer
    case .double: self = .double
    case .string: self = .string
    }
  }
}

/// An advisory requirement for a node or edge property.
public struct PropertyRule: Sendable, Equatable {
  /// The required scalar kind when the property has a non-null value.
  public let kind: ValueKind

  /// Whether the property must be present in a validated property dictionary.
  public let required: Bool

  /// Whether a present null value satisfies this rule.
  public let allowsNull: Bool

  /// Creates a property rule.
  ///
  /// - Parameters:
  ///   - kind: The expected scalar kind.
  ///   - required: Whether the property must be present.
  ///   - allowsNull: Whether a present null is accepted.
  public init(kind: ValueKind, required: Bool = false, allowsNull: Bool = false) {
    self.kind = kind
    self.required = required
    self.allowsNull = allowsNull
  }
}

/// An advisory definition for nodes carrying one label.
public struct NodeSchema: Sendable, Equatable {
  /// The node label this definition validates.
  public let label: String

  /// Rules keyed by property name.
  public let properties: [String: PropertyRule]

  /// Whether properties not listed in ``properties`` are accepted.
  public let allowsAdditionalProperties: Bool

  /// Creates a node schema definition.
  public init(
    label: String,
    properties: [String: PropertyRule] = [:],
    allowsAdditionalProperties: Bool = true
  ) {
    self.label = label
    self.properties = properties
    self.allowsAdditionalProperties = allowsAdditionalProperties
  }
}

/// An advisory definition for edges with one type.
public struct EdgeSchema: Sendable, Equatable {
  /// The edge type this definition validates.
  public let type: String

  /// Rules keyed by property name.
  public let properties: [String: PropertyRule]

  /// Whether properties not listed in ``properties`` are accepted.
  public let allowsAdditionalProperties: Bool

  /// Creates an edge schema definition.
  public init(
    type: String,
    properties: [String: PropertyRule] = [:],
    allowsAdditionalProperties: Bool = true
  ) {
    self.type = type
    self.properties = properties
    self.allowsAdditionalProperties = allowsAdditionalProperties
  }
}

/// A validation failure from ``GraphSchema``.
public enum SchemaValidationError: Error, Sendable, Equatable {
  /// The supplied node label has no schema definition.
  case unknownNodeLabel(String)

  /// The supplied edge type has no schema definition.
  case unknownEdgeType(String)

  /// A required property is absent from an entity's property dictionary.
  case missingRequiredProperty(entity: String, property: String)

  /// A property is not declared by a closed schema definition.
  case unexpectedProperty(entity: String, property: String)

  /// A property's scalar kind does not match its declared rule.
  case invalidPropertyType(entity: String, property: String, expected: ValueKind, actual: ValueKind)
}

/// An opt-in, in-memory schema that validates complete property dictionaries.
///
/// A graph schema is not persisted in LatticeDB and does not impose storage
/// constraints. Use its creation helpers when an application wants validation
/// before creating a node or edge.
public struct GraphSchema: Sendable, Equatable {
  private let nodes: [String: NodeSchema]
  private let edges: [String: EdgeSchema]

  /// Creates a schema from node-label and edge-type definitions.
  public init(nodes: [NodeSchema] = [], edges: [EdgeSchema] = []) {
    self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.label, $0) })
    self.edges = Dictionary(uniqueKeysWithValues: edges.map { ($0.type, $0) })
  }

  /// Validates properties for a node carrying `label`.
  public func validateNode(label: String, properties: [String: Value]) throws {
    guard let schema = nodes[label] else { throw SchemaValidationError.unknownNodeLabel(label) }
    try validate(
      entity: label,
      properties: properties,
      rules: schema.properties,
      allowsAdditionalProperties: schema.allowsAdditionalProperties
    )
  }

  /// Validates properties for an edge with `type`.
  public func validateEdge(type: String, properties: [String: Value]) throws {
    guard let schema = edges[type] else { throw SchemaValidationError.unknownEdgeType(type) }
    try validate(
      entity: type,
      properties: properties,
      rules: schema.properties,
      allowsAdditionalProperties: schema.allowsAdditionalProperties
    )
  }

  /// Validates and creates a labeled node with a complete property dictionary.
  public func createNode(
    in transaction: Transaction,
    label: String,
    properties: [String: Value]
  ) throws -> NodeID {
    try validateNode(label: label, properties: properties)
    let node = try transaction.createNode(label: label)
    try transaction.setProperties(properties, onNode: node)
    return node
  }

  /// Validates and creates an edge with a complete property dictionary.
  public func createEdge(
    in transaction: Transaction,
    from source: NodeID,
    to target: NodeID,
    type: String,
    properties: [String: Value]
  ) throws -> EdgeID {
    try validateEdge(type: type, properties: properties)
    let edge = try transaction.createEdge(from: source, to: target, type: type)
    try transaction.setProperties(properties, onEdge: edge)
    return edge
  }

  private func validate(
    entity: String,
    properties: [String: Value],
    rules: [String: PropertyRule],
    allowsAdditionalProperties: Bool
  ) throws {
    for (name, rule) in rules where rule.required && properties[name] == nil {
      throw SchemaValidationError.missingRequiredProperty(entity: entity, property: name)
    }
    for (name, value) in properties {
      guard let rule = rules[name] else {
        if !allowsAdditionalProperties {
          throw SchemaValidationError.unexpectedProperty(entity: entity, property: name)
        }
        continue
      }
      let actual = ValueKind(value)
      if actual == .null && rule.allowsNull { continue }
      guard actual == rule.kind else {
        throw SchemaValidationError.invalidPropertyType(
          entity: entity,
          property: name,
          expected: rule.kind,
          actual: actual
        )
      }
    }
  }
}

extension Transaction {
  /// Sets every property in `properties` on a node.
  public func setProperties(_ properties: [String: Value], onNode node: NodeID) throws {
    for (key, value) in properties { try setProperty(key, onNode: node, to: value) }
  }

  /// Sets every property in `properties` on an edge.
  public func setProperties(_ properties: [String: Value], onEdge edge: EdgeID) throws {
    for (key, value) in properties { try setProperty(key, onEdge: edge, to: value) }
  }
}
