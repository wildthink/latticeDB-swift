import Foundation

/// A node label, extendable with static members.
///
/// Applications name the labels they model in an extension so call sites can
/// use leading-dot syntax, while unmodeled labels remain expressible as string
/// literals.
///
/// ```swift
/// extension NodeType { public static let person: NodeType = "Person" }
/// ```
public struct NodeType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  /// The label text stored in the graph.
  public let rawValue: String

  /// Creates a node label from its stored text.
  public init(rawValue: String) { self.rawValue = rawValue }

  /// Creates a node label from its stored text.
  public init(_ rawValue: String) { self.rawValue = rawValue }

  /// Creates a node label from a string literal.
  public init(stringLiteral value: String) { self.init(value) }

  public var description: String { rawValue }
}

/// An edge type, extendable with static members.
///
/// ```swift
/// extension EdgeType { public static let knows: EdgeType = "KNOWS" }
/// ```
public struct EdgeType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  /// The edge type text stored in the graph.
  public let rawValue: String

  /// Creates an edge type from its stored text.
  public init(rawValue: String) { self.rawValue = rawValue }

  /// Creates an edge type from its stored text.
  public init(_ rawValue: String) { self.rawValue = rawValue }

  /// Creates an edge type from a string literal.
  public init(stringLiteral value: String) { self.init(value) }

  public var description: String { rawValue }
}

/// A Swift type that converts to and from a stored scalar ``Value``.
///
/// Conform application types to store them in typed property keys. Enumerations
/// backed by a representable raw value receive both requirements for free.
public protocol ValueRepresentable: Sendable {
  /// The scalar kind this type stores, used to generate schema rules.
  static var valueKind: ValueKind { get }

  /// Creates an instance from a stored scalar, or returns `nil` when the scalar
  /// has an incompatible kind.
  init?(latticeValue: Value)

  /// The scalar stored in the graph for this instance.
  var latticeValue: Value { get }
}

extension Value: ValueRepresentable {
  /// An untyped key carries no single kind, so a rule generated from one
  /// constrains nothing.
  public static var valueKind: ValueKind { .null }
  public init?(latticeValue: Value) { self = latticeValue }
  public var latticeValue: Value { self }
}

extension Bool: ValueRepresentable {
  public static var valueKind: ValueKind { .bool }
  public init?(latticeValue: Value) {
    guard case .bool(let value) = latticeValue else { return nil }
    self = value
  }
  public var latticeValue: Value { .bool(self) }
}

extension Int: ValueRepresentable {
  public static var valueKind: ValueKind { .integer }
  public init?(latticeValue: Value) {
    guard case .integer(let value) = latticeValue, let converted = Int(exactly: value) else {
      return nil
    }
    self = converted
  }
  public var latticeValue: Value { .integer(Int64(self)) }
}

extension Int64: ValueRepresentable {
  public static var valueKind: ValueKind { .integer }
  public init?(latticeValue: Value) {
    guard case .integer(let value) = latticeValue else { return nil }
    self = value
  }
  public var latticeValue: Value { .integer(self) }
}

extension Double: ValueRepresentable {
  public static var valueKind: ValueKind { .double }
  /// Accepts both stored doubles and stored integers, because a whole number
  /// written by another writer is still a valid double.
  public init?(latticeValue: Value) {
    switch latticeValue {
    case .double(let value): self = value
    case .integer(let value): self = Double(value)
    default: return nil
    }
  }
  public var latticeValue: Value { .double(self) }
}

extension String: ValueRepresentable {
  public static var valueKind: ValueKind { .string }
  public init?(latticeValue: Value) {
    guard case .string(let value) = latticeValue else { return nil }
    self = value
  }
  public var latticeValue: Value { .string(self) }
}

extension Date: ValueRepresentable {
  public static var valueKind: ValueKind { .integer }
  /// Stored as epoch milliseconds, matching ``TemporalValidity``.
  public init?(latticeValue: Value) {
    guard case .integer(let value) = latticeValue else { return nil }
    self = Date(timeIntervalSince1970: Double(value) / 1_000)
  }
  public var latticeValue: Value {
    .integer(Int64((timeIntervalSince1970 * 1_000).rounded()))
  }
}

extension UUID: ValueRepresentable {
  public static var valueKind: ValueKind { .string }
  /// Stored as an uppercase UUID string.
  public init?(latticeValue: Value) {
    guard case .string(let value) = latticeValue, let uuid = UUID(uuidString: value) else {
      return nil
    }
    self = uuid
  }
  public var latticeValue: Value { .string(uuidString) }
}

extension Optional: ValueRepresentable where Wrapped: ValueRepresentable {
  public static var valueKind: ValueKind { Wrapped.valueKind }
  public init?(latticeValue: Value) {
    if case .null = latticeValue {
      self = .none
    } else if let wrapped = Wrapped(latticeValue: latticeValue) {
      self = .some(wrapped)
    } else {
      return nil
    }
  }
  public var latticeValue: Value { self?.latticeValue ?? .null }
}

extension ValueRepresentable where Self: RawRepresentable, Self.RawValue: ValueRepresentable {
  public static var valueKind: ValueKind { RawValue.valueKind }
  public init?(latticeValue: Value) {
    guard let raw = RawValue(latticeValue: latticeValue), let value = Self(rawValue: raw) else {
      return nil
    }
    self = value
  }
  public var latticeValue: Value { rawValue.latticeValue }
}

/// A property name paired with the Swift type stored under it.
///
/// `Owner` is a phantom type naming the entity that owns the property, so a key
/// declared for one entity cannot be used to read another. Declare keys as
/// static members of the owner; any module may add more.
///
/// ```swift
/// extension Person {
///   public static let name = PropertyKey<Person, String>("name")
/// }
/// ```
public struct PropertyKey<Owner, Value: ValueRepresentable>: Sendable, Hashable {
  /// The property name stored in the graph.
  public let name: String

  /// Creates a typed property key.
  public init(_ name: String) { self.name = name }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
  public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// The namespace that gives an entity's property keys key-path shorthand.
///
/// Declaring keys as static members of the entity is enough to use them
/// everywhere. Add a forwarding member here as well to write `\.name` in the
/// APIs that already know which entity they are working with:
///
/// ```swift
/// extension PropertyKeys where Owner == Person {
///   var name: PropertyKey<Person, String> { Person.name }
///   var age: PropertyKey<Person, Int> { Person.age }
/// }
///
/// try database.match(Person.self).select(\.name).orderBy(\.age).fetchRows()
/// ```
///
/// The shorthand works only where the owning entity is fixed by the API, which
/// is why the explicit spelling stays available everywhere.
public struct PropertyKeys<Owner>: Sendable {
  /// Creates the namespace. Instances carry no state.
  public init() {}
}

extension GraphNode {
  /// The key-path namespace for this entity's properties.
  public static var keys: PropertyKeys<Self> { PropertyKeys<Self>() }
}

/// An entity modeled as a node label with typed property keys.
public protocol GraphNode: Sendable {
  /// The label carried by nodes of this entity.
  static var nodeType: NodeType { get }
}

/// An entity modeled as an edge type with typed property keys.
public protocol GraphEdge: Sendable {
  /// The type carried by edges of this entity.
  static var edgeType: EdgeType { get }
}

/// One property name bound to a stored scalar.
///
/// Produced by the ``.=(_:_:)`` operator or `Property(_:_:)` and collected by
/// ``PropertyBuilder``.
public struct PropertyAssignment: Sendable, Equatable {
  /// The property name.
  public let name: String

  /// The scalar to store.
  public let value: Value

  /// Creates an assignment from an untyped name and scalar.
  public init(_ name: String, _ value: Value) {
    self.name = name
    self.value = value
  }

  /// Creates an assignment from a typed key.
  public init<Owner, V>(_ key: PropertyKey<Owner, V>, _ value: V) {
    self.init(key.name, value.latticeValue)
  }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Creates an untyped property assignment.
///
/// Use this for properties that are not modeled with a ``PropertyKey``.
public func Property(_ name: String, _ value: Value) -> PropertyAssignment {
  PropertyAssignment(name, value)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Creates an untyped property assignment from a representable Swift value.
public func Property(_ name: String, _ value: some ValueRepresentable) -> PropertyAssignment {
  PropertyAssignment(name, value.latticeValue)
}

precedencegroup PropertyAssignmentPrecedence {
  associativity: none
  higherThan: AssignmentPrecedence
  lowerThan: ComparisonPrecedence
}

infix operator .= : PropertyAssignmentPrecedence

/// Binds a typed property key to a value.
public func .= <Owner, V: ValueRepresentable>(
  key: PropertyKey<Owner, V>, value: V
) -> PropertyAssignment {
  PropertyAssignment(key, value)
}

extension Transaction {
  /// Creates a node carrying `type`.
  public func createNode(_ type: NodeType) throws -> NodeID {
    try createNode(label: type.rawValue)
  }

  /// Creates an edge of `type` from `source` to `target`.
  public func createEdge(from source: NodeID, to target: NodeID, type: EdgeType) throws -> EdgeID {
    try createEdge(from: source, to: target, type: type.rawValue)
  }

  /// Deletes the edge of `type` between `source` and `target`.
  public func deleteEdge(from source: NodeID, to target: NodeID, type: EdgeType) throws {
    try deleteEdge(from: source, to: target, type: type.rawValue)
  }

  /// Adds `type` as a label on `node`.
  public func addLabel(_ type: NodeType, to node: NodeID) throws {
    try addLabel(type.rawValue, to: node)
  }

  /// Removes the label `type` from `node`.
  public func removeLabel(_ type: NodeType, from node: NodeID) throws {
    try removeLabel(type.rawValue, from: node)
  }

  /// Returns every node identifier carrying `type`.
  public func nodeIDs(_ type: NodeType) throws -> [NodeID] {
    try nodeIDs(label: type.rawValue)
  }

  /// Returns every node identifier carrying the label of `entity`.
  public func nodeIDs<Entity: GraphNode>(of entity: Entity.Type) throws -> [NodeID] {
    try nodeIDs(label: Entity.nodeType.rawValue)
  }

  /// Returns the labels of `node` as ``NodeType`` values.
  public func nodeTypes(of node: NodeID) throws -> [NodeType] {
    try labels(of: node).map { NodeType($0) }
  }

  /// Sets a typed property on a node.
  public func setProperty<Owner, V: ValueRepresentable>(
    _ key: PropertyKey<Owner, V>, onNode node: NodeID, to value: V
  ) throws {
    try setProperty(key.name, onNode: node, to: value.latticeValue)
  }

  /// Sets a typed property on an edge.
  public func setProperty<Owner, V: ValueRepresentable>(
    _ key: PropertyKey<Owner, V>, onEdge edge: EdgeID, to value: V
  ) throws {
    try setProperty(key.name, onEdge: edge, to: value.latticeValue)
  }

  /// Applies every assignment to a node.
  public func apply(_ assignments: [PropertyAssignment], onNode node: NodeID) throws {
    for assignment in assignments {
      try setProperty(assignment.name, onNode: node, to: assignment.value)
    }
  }

  /// Applies every assignment to an edge.
  public func apply(_ assignments: [PropertyAssignment], onEdge edge: EdgeID) throws {
    for assignment in assignments {
      try setProperty(assignment.name, onEdge: edge, to: assignment.value)
    }
  }
}

extension [PropertyAssignment] {
  /// Returns these assignments as a property dictionary.
  ///
  /// Later assignments to the same name win, matching the order they were
  /// declared in a builder body.
  public var propertyValues: [String: Value] {
    reduce(into: [:]) { $0[$1.name] = $1.value }
  }
}
