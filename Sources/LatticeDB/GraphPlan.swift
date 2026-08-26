import Foundation

/// A declarative description of nodes and edges, applied inside one transaction.
///
/// A plan is a value: building one performs no work and touches no database, so
/// plans can be constructed anywhere, passed across concurrency domains, and
/// inspected in tests. ``apply(in:schema:mergeStrategy:)`` performs the writes.
///
/// ```swift
/// let plan = GraphPlan {
///   let ada = Node(.person) { Person.name .= "Ada Chen" }
///   let cafe = Node("Place") { Property("name", .string("River Cafe")) }
///   Edge(.frequents, from: ada, to: cafe)
/// }
/// let result = try database.write { try plan.apply(in: $0) }
/// ```
///
/// A node bound to a `let` inside the builder joins the plan when an edge
/// references it. Declare a node that stands alone as its own statement.
public struct GraphPlan: Sendable {
  /// The declarations in the order they were written.
  public var elements: [GraphElement]

  /// Creates a plan from already-built elements.
  public init(elements: [GraphElement] = []) { self.elements = elements }

  /// Creates a plan from a builder body.
  public init(@GraphBuilder _ content: () -> GraphPlan) { self = content() }

  /// The node declarations written as statements, in order.
  public var nodeSpecs: [NodeSpec] {
    elements.compactMap { element in
      guard case .node(let spec) = element else { return nil }
      return spec
    }
  }

  /// The edge declarations, in order.
  public var edgeSpecs: [EdgeSpec] {
    elements.compactMap { element in
      guard case .edge(let spec) = element else { return nil }
      return spec
    }
  }

  /// Returns a plan containing this plan's declarations followed by `other`'s.
  public func appending(_ other: GraphPlan) -> GraphPlan {
    GraphPlan(elements: elements + other.elements)
  }
}

/// A failure raised while applying a ``GraphPlan``.
public enum GraphPlanError: Error, Sendable, Equatable {
  /// A declared node identifier does not exist in the transaction's view.
  case missingNode(NodeID)

  /// A merge needs an equality index that does not exist.
  ///
  /// Create it with ``Database/createNodeIndex(label:property:)``, or apply the
  /// plan with ``MergeStrategy/scanIfUnindexed``.
  case indexRequired(label: String, property: String)

  /// A merge matched more than one node, so there is no single node to reuse.
  case ambiguousMerge(label: String, property: String, matches: Int)

  /// A merge was declared on a node carrying no label to match against.
  case mergeRequiresLabel(property: String)
}

/// The identifiers produced by applying a ``GraphPlan``.
public struct GraphApplyResult: Sendable {
  /// The node identifier resolved for each declared node.
  public let nodes: [NodeRef: NodeID]

  /// The identifiers of every edge created, in declaration order.
  public let edges: [EdgeID]

  /// Returns the identifier resolved for a declared node.
  public subscript(spec: NodeSpec) -> NodeID? { nodes[spec.ref] }

  /// Returns the identifier resolved for a node reference.
  public subscript(ref: NodeRef) -> NodeID? { nodes[ref] }

  /// Returns the identifier resolved for a declared node, or `nil` when the
  /// node was not part of the applied plan.
  public func id(of spec: NodeSpec) -> NodeID? { nodes[spec.ref] }
}

extension GraphPlan {
  /// Applies every declaration inside `transaction`.
  ///
  /// Nodes are created or resolved in declaration order; an edge whose endpoint
  /// was declared but never written as a statement resolves that node the first
  /// time an edge needs it.
  ///
  /// When `schema` is supplied, every declaration is validated before any write
  /// happens, so a validation failure leaves the graph untouched. Declarations
  /// carrying no label are not validated, because there is no definition to
  /// validate them against.
  ///
  /// - Parameters:
  ///   - transaction: The transaction to write in. Use a writable transaction.
  ///   - schema: An optional advisory schema.
  ///   - mergeStrategy: What a merge does when no equality index supports it.
  /// - Returns: The identifiers produced by the plan.
  @discardableResult
  public func apply(
    in transaction: Transaction,
    schema: GraphSchema? = nil,
    mergeStrategy: MergeStrategy = .indexOnly
  ) throws -> GraphApplyResult {
    if let schema { try validate(with: schema) }

    var context = ApplyContext(transaction: transaction, mergeStrategy: mergeStrategy)

    for element in elements {
      switch element {
      case .node(let spec):
        _ = try resolve(spec, in: &context)
      case .edge(let spec):
        let source = try resolve(spec.source, in: &context)
        let target = try resolve(spec.target, in: &context)
        let edge = try resolveEdge(spec, from: source, to: target, in: context)
        try transaction.apply(spec.properties, onEdge: edge)
        context.edges.append(edge)
      case .mutation(let mutation):
        try apply(mutation, in: &context)
      }
    }

    return GraphApplyResult(nodes: context.resolved, edges: context.edges)
  }

  /// Validates every labeled declaration against `schema` without writing.
  public func validate(with schema: GraphSchema) throws {
    for element in elements {
      switch element {
      case .node(let spec):
        guard let label = spec.labels.first else { continue }
        try schema.validateNode(label: label.rawValue, properties: spec.properties.propertyValues)
      case .edge(let spec):
        try schema.validateEdge(
          type: spec.type.rawValue, properties: spec.properties.propertyValues)
        for endpoint in [spec.source, spec.target] {
          guard case .spec(let node) = endpoint, let label = node.labels.first else { continue }
          try schema.validateNode(
            label: label.rawValue, properties: node.properties.propertyValues)
        }
      case .mutation:
        continue
      }
    }
  }

  private struct ApplyContext {
    let transaction: Transaction
    let mergeStrategy: MergeStrategy
    var resolved: [NodeRef: NodeID] = [:]
    var edges: [EdgeID] = []
  }

  private func resolve(_ target: NodeTarget, in context: inout ApplyContext) throws -> NodeID {
    switch target {
    case .spec(let spec):
      return try resolve(spec, in: &context)
    case .id(let id):
      guard try context.transaction.nodeExists(id) else { throw GraphPlanError.missingNode(id) }
      return id
    }
  }

  private func resolve(_ spec: NodeSpec, in context: inout ApplyContext) throws -> NodeID {
    if let existing = context.resolved[spec.ref] { return existing }

    let transaction = context.transaction
    let id: NodeID
    var pendingLabels = spec.labels[...]
    switch spec.identity {
    case .create:
      id = try transaction.createNode(label: pendingLabels.popFirst()?.rawValue)
    case .existing(let existing):
      guard try transaction.nodeExists(existing) else {
        throw GraphPlanError.missingNode(existing)
      }
      id = existing
    case .merge(let property, let value):
      guard let label = spec.labels.first else {
        throw GraphPlanError.mergeRequiresLabel(property: property)
      }
      if let matched = try matchExistingNode(
        label: label, property: property, value: value, in: context)
      {
        id = matched
      } else {
        id = try transaction.createNode(label: pendingLabels.popFirst()?.rawValue)
        try transaction.setProperty(property, onNode: id, to: value)
      }
    }
    for label in pendingLabels { try transaction.addLabel(label, to: id) }
    try transaction.apply(spec.properties, onNode: id)

    context.resolved[spec.ref] = id
    return id
  }

  private func matchExistingNode(
    label: NodeType, property: String, value: Value, in context: ApplyContext
  ) throws -> NodeID? {
    let transaction = context.transaction
    var matches: [NodeID]
    do {
      matches = try transaction.nodeIDs(label: label.rawValue, property: property, equals: value)
    } catch GraphPlanError.indexRequired where context.mergeStrategy == .scanIfUnindexed {
      matches = try transaction.nodeIDs(label: label.rawValue).filter {
        try transaction.propertyValue(property, ofNode: $0) == value
      }
    }
    guard matches.count <= 1 else {
      throw GraphPlanError.ambiguousMerge(
        label: label.rawValue, property: property, matches: matches.count)
    }
    return matches.first
  }

  private func resolveEdge(
    _ spec: EdgeSpec, from source: NodeID, to target: NodeID, in context: ApplyContext
  ) throws -> EdgeID {
    let transaction = context.transaction
    if case .merge = spec.identity {
      let existing = try transaction.edges(for: source, outgoing: true, type: spec.type)
        .first { $0.target == target }
      if let existing { return existing.id }
    }
    return try transaction.createEdge(from: source, to: target, type: spec.type)
  }

  private func apply(_ mutation: GraphMutation, in context: inout ApplyContext) throws {
    let transaction = context.transaction
    switch mutation {
    case .deleteNode(let target):
      try transaction.deleteNode(try resolve(target, in: &context))
    case .addLabel(let label, let target):
      try transaction.addLabel(label, to: try resolve(target, in: &context))
    case .removeLabel(let label, let target):
      try transaction.removeLabel(label, from: try resolve(target, in: &context))
    case .deleteEdge(let type, let source, let target):
      let from = try resolve(source, in: &context)
      let to = try resolve(target, in: &context)
      try transaction.deleteEdge(from: from, to: to, type: type)
    }
  }
}

extension Database {
  /// Applies a graph declaration in one write transaction.
  ///
  /// The transaction commits when the body completes and rolls back if any
  /// declaration fails.
  ///
  /// ```swift
  /// let result = try database.apply {
  ///   let ada = Node(.person) { Person.name .= "Ada Chen" }
  ///   Edge(.knows, from: ada, to: Node(.person) { Person.name .= "Bo Lin" })
  /// }
  /// ```
  @discardableResult
  public func apply(
    schema: GraphSchema? = nil,
    mergeStrategy: MergeStrategy = .indexOnly,
    @GraphBuilder _ content: () -> GraphPlan
  ) throws -> GraphApplyResult {
    let plan = content()
    return try write { try plan.apply(in: $0, schema: schema, mergeStrategy: mergeStrategy) }
  }

  /// Applies a graph declaration in one write transaction.
  ///
  /// This is ``apply(schema:mergeStrategy:_:)`` under the name that reads better
  /// when the plan changes existing data rather than seeding new data.
  ///
  /// ```swift
  /// try database.update {
  ///   Upsert(.person, matching: Person.email, "ada@example.com") {
  ///     Person.name .= "Ada Chen"
  ///   }
  ///   Delete(node: staleID)
  /// }
  /// ```
  @discardableResult
  public func update(
    schema: GraphSchema? = nil,
    mergeStrategy: MergeStrategy = .indexOnly,
    @GraphBuilder _ content: () -> GraphPlan
  ) throws -> GraphApplyResult {
    try apply(schema: schema, mergeStrategy: mergeStrategy, content)
  }
}

extension Transaction {
  /// Applies a graph declaration inside this transaction.
  @discardableResult
  public func apply(
    schema: GraphSchema? = nil,
    mergeStrategy: MergeStrategy = .indexOnly,
    @GraphBuilder _ content: () -> GraphPlan
  ) throws -> GraphApplyResult {
    try content().apply(in: self, schema: schema, mergeStrategy: mergeStrategy)
  }
}
