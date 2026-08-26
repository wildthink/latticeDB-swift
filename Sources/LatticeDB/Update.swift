import Foundation

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a node matched by a property, created when no match exists.
///
/// Matching uses the equality index for `type` and the key's property. Create it
/// once with ``Database/createNodeIndex(label:property:)``; without it, applying
/// throws ``GraphPlanError/indexRequired(label:property:)`` unless the plan
/// is applied with ``MergeStrategy/scanIfUnindexed``.
///
/// ```swift
/// try database.update {
///   Upsert(.person, matching: Person.email, "ada@example.com") {
///     Person.name .= "Ada Chen"
///   }
/// }
/// ```
public func Upsert<Owner, V: ValueRepresentable>(
  _ type: NodeType,
  matching key: PropertyKey<Owner, V>,
  _ value: V,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> NodeSpec {
  NodeSpec(
    labels: [type],
    properties: properties(),
    identity: .merge(property: key.name, value: value.latticeValue)
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a node matched by an untyped property, created when no match exists.
public func Upsert(
  _ type: NodeType,
  matching property: String,
  equals value: Value,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> NodeSpec {
  NodeSpec(
    labels: [type],
    properties: properties(),
    identity: .merge(property: property, value: value)
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a node matched by the modeled entity's label and a property.
public func Upsert<Entity: GraphNode, Owner, V: ValueRepresentable>(
  _ entity: Entity.Type,
  matching key: PropertyKey<Owner, V>,
  _ value: V,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> NodeSpec {
  Upsert(Entity.nodeType, matching: key, value, properties: properties)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares an edge that is created only when it does not already exist.
///
/// An edge is considered to exist when an edge of the same type already runs
/// from the source to the target. Properties are written either way, so this
/// both connects and refreshes.
public func Connect(
  _ type: EdgeType,
  from source: some NodeReference,
  to target: some NodeReference,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> EdgeSpec {
  EdgeSpec(
    type: type,
    source: source.nodeTarget,
    target: target.nodeTarget,
    properties: properties(),
    identity: .merge
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares property changes for an existing node.
public func Update(
  node id: NodeID,
  @PropertyBuilder properties: () -> [PropertyAssignment]
) -> NodeSpec {
  NodeSpec(labels: [], properties: properties(), identity: .existing(id))
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares that a node is deleted along with the graph state attached to it.
public func Delete(node: some NodeReference) -> GraphMutation {
  .deleteNode(node.nodeTarget)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares that an edge of `type` between two nodes is deleted.
public func Disconnect(
  _ type: EdgeType, from source: some NodeReference, to target: some NodeReference
) -> GraphMutation {
  .deleteEdge(type, source: source.nodeTarget, target: target.nodeTarget)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares that a label is added to a node.
public func AddLabel(_ label: NodeType, to node: some NodeReference) -> GraphMutation {
  .addLabel(label, node.nodeTarget)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares that a label is removed from a node.
public func RemoveLabel(_ label: NodeType, from node: some NodeReference) -> GraphMutation {
  .removeLabel(label, node.nodeTarget)
}

/// A typed view of one node inside a transaction.
///
/// A handle is a cursor for read-modify-write work, where a ``GraphPlan``
/// describes writes up front. It borrows its transaction and must not outlive
/// the closure that vended it.
///
/// ```swift
/// try database.write { transaction in
///   let ada = transaction.node(adaID, as: Person.self)
///   let age = try ada[Person.age] ?? 0
///   try ada.set(Person.age, age + 1)
/// }
/// ```
public struct NodeHandle<Owner: GraphNode> {
  /// The node this handle refers to.
  public let id: NodeID

  private let transaction: Transaction

  init(id: NodeID, transaction: Transaction) {
    self.id = id
    self.transaction = transaction
  }

  /// Reads a typed property, or `nil` when it is unset.
  public subscript<V: ValueRepresentable>(key: PropertyKey<Owner, V>) -> V? {
    get throws { try transaction.property(key, ofNode: id) }
  }

  /// Whether the node still exists in this transaction's view.
  public var exists: Bool {
    get throws { try transaction.nodeExists(id) }
  }

  /// The node's labels.
  public var labels: [NodeType] {
    get throws { try transaction.nodeTypes(of: id) }
  }

  /// Writes a typed property.
  public func set<V: ValueRepresentable>(_ key: PropertyKey<Owner, V>, _ value: V) throws {
    try transaction.setProperty(key, onNode: id, to: value)
  }

  /// Writes every assignment in a builder body.
  public func set(@PropertyBuilder _ properties: () -> [PropertyAssignment]) throws {
    try transaction.apply(properties(), onNode: id)
  }

  /// Adds a label.
  public func addLabel(_ label: NodeType) throws {
    try transaction.addLabel(label, to: id)
  }

  /// Removes a label.
  public func removeLabel(_ label: NodeType) throws {
    try transaction.removeLabel(label, from: id)
  }

  /// Returns the node's edges.
  public func edges(outgoing: Bool = true, type: EdgeType? = nil) throws -> [EdgeSnapshot] {
    try transaction.edges(for: id, outgoing: outgoing, type: type)
  }

  /// Returns the nodes reached over edges of `type`, as typed handles.
  public func neighbors<Other: GraphNode>(
    _ other: Other.Type, outgoing: Bool = true, type: EdgeType? = nil
  ) throws -> [NodeHandle<Other>] {
    try transaction.neighbors(of: id, outgoing: outgoing, type: type)
      .map { NodeHandle<Other>(id: $0, transaction: transaction) }
  }

  /// Deletes the node.
  public func delete() throws {
    try transaction.deleteNode(id)
  }
}

extension Transaction {
  /// Returns a typed handle for an existing node.
  ///
  /// The handle is not checked against the graph; read ``NodeHandle/exists`` if
  /// the node may have been deleted.
  public func node<Owner: GraphNode>(_ id: NodeID, as owner: Owner.Type) -> NodeHandle<Owner> {
    NodeHandle(id: id, transaction: self)
  }

  /// Returns typed handles for every node carrying the entity's label.
  public func nodes<Owner: GraphNode>(of owner: Owner.Type) throws -> [NodeHandle<Owner>] {
    try nodeIDs(label: Owner.nodeType.rawValue).map { NodeHandle(id: $0, transaction: self) }
  }
}

extension NodeHandle {
  /// Reads a typed property addressed by key path.
  ///
  /// Requires a forwarding member on ``PropertyKeys``; see its documentation.
  public subscript<V: ValueRepresentable>(
    key: KeyPath<PropertyKeys<Owner>, PropertyKey<Owner, V>>
  ) -> V? {
    get throws { try self[PropertyKeys<Owner>()[keyPath: key]] }
  }

  /// Writes a typed property addressed by key path.
  public func set<V: ValueRepresentable>(
    _ key: KeyPath<PropertyKeys<Owner>, PropertyKey<Owner, V>>, _ value: V
  ) throws {
    try set(PropertyKeys<Owner>()[keyPath: key], value)
  }
}
