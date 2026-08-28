import Foundation

/// The identity token of a node declared in a ``GraphPlan``.
///
/// A reference is created with the node that declares it and stays the same
/// through every copy of that declaration, so edges resolve to the node the
/// plan built rather than to a repeated creation.
public final class NodeRef: Hashable, Sendable {
  /// Creates a fresh reference.
  public init() {}

  public static func == (lhs: NodeRef, rhs: NodeRef) -> Bool { lhs === rhs }
  public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// How a declared node maps onto a node in the graph.
public enum NodeIdentity: Sendable, Equatable {
  /// Create a new node when the plan is applied.
  case create

  /// Use the existing node with this identifier.
  case existing(NodeID)

  /// Reuse the node whose `property` equals `value`, creating it when absent.
  ///
  /// Matching goes through the explicit equality index for the node's primary
  /// label; see ``MergeStrategy`` for what happens when no index exists.
  case merge(property: String, value: Value)
}

/// How a declared edge maps onto an edge in the graph.
public enum EdgeIdentity: Sendable, Equatable {
  /// Create an edge every time the plan is applied.
  case create

  /// Reuse an existing edge of the same type between the same endpoints.
  case merge
}

/// What ``NodeIdentity/merge(property:value:)`` does without a supporting index.
public enum MergeStrategy: Sendable, Equatable {
  /// Require an equality index and fail when one is missing. The default: a
  /// silent full-label scan is worse than an error naming the missing index.
  case indexOnly

  /// Fall back to scanning every node carrying the label.
  case scanIfUnindexed
}

/// A node declared in a ``GraphPlan``.
///
/// Build one with `Node(_:properties:)` rather than calling the initializer
/// directly.
public struct NodeSpec: Sendable, Equatable {
  /// The identity token used by edges that reference this node.
  public let ref: NodeRef

  /// The labels applied to the node, primary label first.
  public var labels: [NodeType]

  /// The properties written when the plan is applied.
  public var properties: [PropertyAssignment]

  /// Whether the node is created or already exists.
  public var identity: NodeIdentity

  /// Creates a node declaration.
  public init(
    ref: NodeRef = NodeRef(),
    labels: [NodeType] = [],
    properties: [PropertyAssignment] = [],
    identity: NodeIdentity = .create
  ) {
    self.ref = ref
    self.labels = labels
    self.properties = properties
    self.identity = identity
  }
}

/// A value that identifies a node an edge connects to.
public protocol NodeReference {
  /// The endpoint this value refers to.
  var nodeTarget: NodeTarget { get }
}

/// One endpoint of a declared edge.
public enum NodeTarget: Sendable {
  /// A node declared in the same plan.
  case spec(NodeSpec)

  /// A node that already exists in the graph.
  case id(NodeID)
}

extension NodeSpec: NodeReference {
  public var nodeTarget: NodeTarget { .spec(self) }
}

extension NodeTarget: NodeReference {
  public var nodeTarget: NodeTarget { self }
}

extension NodeID: NodeReference {
  public var nodeTarget: NodeTarget { .id(self) }
}

/// An edge declared in a ``GraphPlan``.
///
/// Build one with `Edge(_:from:to:properties:)`.
public struct EdgeSpec: Sendable {
  /// The edge type.
  public var type: EdgeType

  /// The source endpoint.
  public var source: NodeTarget

  /// The target endpoint.
  public var target: NodeTarget

  /// The properties written when the plan is applied.
  public var properties: [PropertyAssignment]

  /// Whether the edge is always created or reused when it already exists.
  public var identity: EdgeIdentity

  /// Creates an edge declaration.
  public init(
    type: EdgeType,
    source: NodeTarget,
    target: NodeTarget,
    properties: [PropertyAssignment] = [],
    identity: EdgeIdentity = .create
  ) {
    self.type = type
    self.source = source
    self.target = target
    self.properties = properties
    self.identity = identity
  }
}

/// A change to graph state that is not a node or edge declaration.
public enum GraphMutation: Sendable {
  /// Delete a node and the graph state attached to it.
  case deleteNode(NodeTarget)

  /// Add a label to a node.
  case addLabel(NodeType, NodeTarget)

  /// Remove a label from a node.
  case removeLabel(NodeType, NodeTarget)

  /// Delete the edge of a type between two nodes.
  case deleteEdge(EdgeType, source: NodeTarget, target: NodeTarget)
}

/// One declaration in a ``GraphPlan``.
public enum GraphElement: Sendable {
  /// A declared node.
  case node(NodeSpec)

  /// A declared edge.
  case edge(EdgeSpec)

  /// A change to existing graph state.
  case mutation(GraphMutation)
}

/// A reusable fragment of a graph declaration.
public protocol GraphComponent {
  /// The declarations this component contributes.
  @GraphBuilder var body: GraphPlan { get }
}

/// Collects node and edge declarations into a ``GraphPlan``.
///
/// The builder supports `if`, `if let`, `if/else`, `switch`, and `for` bodies.
@resultBuilder
public enum GraphBuilder {
  public static func buildExpression(_ node: NodeSpec) -> [GraphElement] { [.node(node)] }

  public static func buildExpression(_ edge: EdgeSpec) -> [GraphElement] { [.edge(edge)] }

  public static func buildExpression(_ element: GraphElement) -> [GraphElement] { [element] }

  public static func buildExpression(_ mutation: GraphMutation) -> [GraphElement] {
    [.mutation(mutation)]
  }

  public static func buildExpression(_ elements: [GraphElement]) -> [GraphElement] { elements }

  public static func buildExpression(_ plan: GraphPlan) -> [GraphElement] { plan.elements }

  public static func buildExpression(_ component: some GraphComponent) -> [GraphElement] {
    component.body.elements
  }

  public static func buildExpression(_ void: Void) -> [GraphElement] { [] }

  public static func buildBlock(_ components: [GraphElement]...) -> [GraphElement] {
    components.flatMap { $0 }
  }

  public static func buildOptional(_ component: [GraphElement]?) -> [GraphElement] {
    component ?? []
  }

  public static func buildEither(first component: [GraphElement]) -> [GraphElement] { component }

  public static func buildEither(second component: [GraphElement]) -> [GraphElement] { component }

  public static func buildArray(_ components: [[GraphElement]]) -> [GraphElement] {
    components.flatMap { $0 }
  }

  public static func buildLimitedAvailability(_ component: [GraphElement]) -> [GraphElement] {
    component
  }

  public static func buildFinalResult(_ component: [GraphElement]) -> GraphPlan {
    GraphPlan(elements: component)
  }
}

/// Collects property assignments inside a node or edge declaration.
@resultBuilder
public enum PropertyBuilder {
  public static func buildExpression(_ assignment: PropertyAssignment) -> [PropertyAssignment] {
    [assignment]
  }

  public static func buildExpression(
    _ assignments: [PropertyAssignment]
  ) -> [PropertyAssignment] {
    assignments
  }

  public static func buildExpression(_ void: Void) -> [PropertyAssignment] { [] }

  public static func buildBlock(_ components: [PropertyAssignment]...) -> [PropertyAssignment] {
    components.flatMap { $0 }
  }

  public static func buildOptional(_ component: [PropertyAssignment]?) -> [PropertyAssignment] {
    component ?? []
  }

  public static func buildEither(first component: [PropertyAssignment]) -> [PropertyAssignment] {
    component
  }

  public static func buildEither(second component: [PropertyAssignment]) -> [PropertyAssignment] {
    component
  }

  public static func buildArray(
    _ components: [[PropertyAssignment]]
  ) -> [PropertyAssignment] {
    components.flatMap { $0 }
  }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a node to create, carrying zero or more labels.
///
/// ```swift
/// let ada = Node(.person) {
///   Person.name .= "Ada Chen"
/// }
/// ```
public func Node(
  _ labels: NodeType...,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> NodeSpec {
  NodeSpec(labels: labels, properties: properties(), identity: .create)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares a node to create, carrying the label of a modeled entity.
public func Node<Entity: GraphNode>(
  _ entity: Entity.Type,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> NodeSpec {
  NodeSpec(labels: [Entity.nodeType], properties: properties(), identity: .create)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares an existing node, optionally adding labels and properties to it.
///
/// Applying a plan containing a missing identifier throws
/// ``GraphPlanError/missingNode(_:)`` before any other element is written.
public func Node(
  existing id: NodeID,
  adding labels: NodeType...,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> NodeSpec {
  NodeSpec(labels: labels, properties: properties(), identity: .existing(id))
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares an edge between two nodes of the same plan, or existing nodes.
///
/// ```swift
/// Edge(.knows, from: ada, to: bo) {
///   Property("since", .integer(2019))
/// }
/// ```
public func Edge(
  _ type: EdgeType,
  from source: some NodeReference,
  to target: some NodeReference,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> EdgeSpec {
  EdgeSpec(
    type: type,
    source: source.nodeTarget,
    target: target.nodeTarget,
    properties: properties()
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Declares an edge of a modeled entity's type.
public func Edge<Entity: GraphEdge>(
  _ entity: Entity.Type,
  from source: some NodeReference,
  to target: some NodeReference,
  @PropertyBuilder properties: () -> [PropertyAssignment] = { [] }
) -> EdgeSpec {
  EdgeSpec(
    type: Entity.edgeType,
    source: source.nodeTarget,
    target: target.nodeTarget,
    properties: properties()
  )
}
