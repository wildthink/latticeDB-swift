import Foundation

/// The direction an edge is traversed in.
public enum TraversalDirection: Sendable {
  /// Follow edges leaving the current node.
  case outgoing
  /// Follow edges arriving at the current node.
  case incoming
}

/// The order a result is sorted in.
public enum SortDirection: String, Sendable {
  case ascending = "ASC"
  case descending = "DESC"
}

struct QueryStep: Sendable {
  var label: NodeType?
  var variable: String
  var edge: EdgeType?
  var direction: TraversalDirection = .outgoing
}

struct QueryProjection: Sendable {
  var variable: String
  var property: String
  var alias: String
}

struct QuerySort: Sendable {
  var variable: String
  var property: String
  var direction: SortDirection
}

/// A type-safe pattern query over a modeled node entity.
///
/// A query is a value that renders to a ``Cypher`` fragment; nothing runs until
/// a `fetch` method is called. `Root` is the entity at the current end of the
/// pattern, so a traversal changes what later clauses can refer to.
///
/// ```swift
/// let names = try database.match(Person.self)
///   .where(Person.age >= 21)
///   .outgoing(.knows, to: Person.self)
///   .select(Person.name)
///   .orderBy(Person.name)
///   .limit(10)
///   .fetchRows()
/// ```
///
/// Read ``cypher`` to inspect the rendered query and its bound parameters
/// without a database — that is the cheapest way to test one.
public struct Query<Root: GraphNode> {
  var steps: [QueryStep]
  var conditions: [(variable: String, predicate: Predicate)] = []
  var projections: [QueryProjection] = []
  var sorts: [QuerySort] = []
  var limitCount: Int?
  var skipCount: Int?
  var isDistinct = false

  let database: Database?

  init(steps: [QueryStep], database: Database?) {
    self.steps = steps
    self.database = database
  }

  /// Creates a query rooted at an entity, for rendering without a database.
  public init(_ root: Root.Type) {
    self.init(steps: [QueryStep(label: Root.nodeType, variable: "v0")], database: nil)
  }

  /// The variable naming the current end of the pattern.
  public var variable: String { steps.last?.variable ?? "v0" }

  private func rebased<Next: GraphNode>(_ next: Next.Type) -> Query<Next> {
    var query = Query<Next>(steps: steps, database: database)
    query.conditions = conditions
    query.projections = projections
    query.sorts = sorts
    query.limitCount = limitCount
    query.skipCount = skipCount
    query.isDistinct = isDistinct
    return query
  }

  // MARK: - Building

  /// Adds a condition on the current pattern variable.
  ///
  /// Repeated calls are combined with `AND`.
  public func `where`(_ predicate: Predicate) -> Query {
    var copy = self
    copy.conditions.append((variable, predicate))
    return copy
  }

  /// Adds another condition on the current pattern variable.
  public func and(_ predicate: Predicate) -> Query { self.where(predicate) }

  /// Adds a valid-time condition on the current pattern variable.
  ///
  /// This qualifies currently stored records by their application-level
  /// ``TemporalValidity`` interval; it is not a historical snapshot.
  public func validAt(_ asOf: TemporalAsOf) -> Query {
    self.where(Predicate(.temporal(asOf)))
  }

  /// Adds a valid-time condition using the default property keys.
  public func validAt(
    _ date: Date, fromKey: String = "validFrom", toKey: String = "validTo"
  ) throws -> Query {
    try validAt(TemporalAsOf(date: date, fromKey: fromKey, toKey: toKey))
  }

  /// Follows outgoing edges of `type` to another entity.
  public func outgoing<Next: GraphNode>(
    _ type: EdgeType, to next: Next.Type, as name: String? = nil
  ) -> Query<Next> {
    traverse(type, to: next, direction: .outgoing, name: name)
  }

  /// Follows incoming edges of `type` from another entity.
  public func incoming<Next: GraphNode>(
    _ type: EdgeType, from next: Next.Type, as name: String? = nil
  ) -> Query<Next> {
    traverse(type, to: next, direction: .incoming, name: name)
  }

  private func traverse<Next: GraphNode>(
    _ type: EdgeType, to next: Next.Type, direction: TraversalDirection, name: String?
  ) -> Query<Next> {
    var query = rebased(next)
    query.steps.append(
      QueryStep(
        label: Next.nodeType,
        variable: name ?? "v\(steps.count)",
        edge: type,
        direction: direction
      )
    )
    return query
  }

  /// Returns a property of the current entity as a result column.
  ///
  /// A query with no selected property returns the identifiers of the nodes at
  /// the current end of the pattern.
  public func select<V>(_ key: PropertyKey<Root, V>, as alias: String? = nil) -> Query {
    var copy = self
    copy.projections.append(
      QueryProjection(variable: variable, property: key.name, alias: alias ?? key.name)
    )
    return copy
  }

  /// Sorts by a property of the current entity.
  public func orderBy<V>(
    _ key: PropertyKey<Root, V>, _ direction: SortDirection = .ascending
  ) -> Query {
    var copy = self
    copy.sorts.append(QuerySort(variable: variable, property: key.name, direction: direction))
    return copy
  }

  /// Returns at most `count` rows.
  public func limit(_ count: Int) -> Query {
    var copy = self
    copy.limitCount = count
    return copy
  }

  /// Skips the first `count` rows.
  public func skip(_ count: Int) -> Query {
    var copy = self
    copy.skipCount = count
    return copy
  }

  /// Removes duplicate rows from the result.
  public func distinct() -> Query {
    var copy = self
    copy.isDistinct = true
    return copy
  }

  // MARK: - Rendering

  /// The rendered query, returning the selected properties or the current
  /// node's identifiers.
  public var cypher: Cypher {
    if projections.isEmpty {
      return render(returning: "\(identifier: variable)")
    }
    var columns: Cypher = ""
    for (index, projection) in projections.enumerated() {
      let column: Cypher =
        "\(identifier: projection.variable).\(identifier: projection.property) "
        + "AS \(identifier: projection.alias)"
      columns = index == 0 ? column : "\(columns), \(column)"
    }
    return render(returning: columns)
  }

  /// The rendered query, counting matched rows into a `total` column.
  ///
  /// Sorting, pagination, and `DISTINCT` are dropped: they change which rows are
  /// returned, not how many the pattern matches.
  public var countCypher: Cypher {
    render(returning: "count(\(identifier: variable)) AS total", forCount: true)
  }

  private func render(returning columns: Cypher, forCount: Bool = false) -> Cypher {
    var query: Cypher = "MATCH "
    for (index, step) in steps.enumerated() {
      if index > 0, let edge = step.edge {
        query =
          step.direction == .outgoing
          ? "\(query)-[:\(edge)]->" : "\(query)<-[:\(edge)]-"
      }
      let label: Cypher = step.label.map { "\(identifier: $0.rawValue)" } ?? ""
      query =
        step.label == nil
        ? "\(query)(\(identifier: step.variable))"
        : "\(query)(\(identifier: step.variable):\(label))"
    }

    // Every condition is parenthesized so that combining independent `where`
    // calls with AND cannot regroup an OR inside one of them.
    for (index, condition) in conditions.enumerated() {
      let fragment = condition.predicate.render(variable: condition.variable)
      query = index == 0 ? "\(query) WHERE (\(fragment))" : "\(query) AND (\(fragment))"
    }

    query =
      isDistinct && !forCount
      ? "\(query) RETURN DISTINCT \(columns)" : "\(query) RETURN \(columns)"

    if !forCount {
      for (index, sort) in sorts.enumerated() {
        let clause: Cypher =
          "\(identifier: sort.variable).\(identifier: sort.property) "
          + "\(raw: sort.direction.rawValue)"
        query = index == 0 ? "\(query) ORDER BY \(clause)" : "\(query), \(clause)"
      }
      if let skipCount { query = "\(query) SKIP \(raw: String(skipCount))" }
      if let limitCount { query = "\(query) LIMIT \(raw: String(limitCount))" }
    }
    return query
  }

  // MARK: - Running

  private func requireDatabase() throws -> Database {
    guard let database else { throw QueryError.detachedQuery }
    return database
  }

  /// Runs the query and returns its rows.
  public func fetchRows() throws -> [Row] {
    try requireDatabase().match(cypher)
  }

  /// Runs the query and decodes each row.
  public func fetch<T: Decodable>(as type: T.Type) throws -> [T] {
    try requireDatabase().match(cypher, as: type)
  }

  /// Runs the query and returns the identifiers of the matched nodes.
  ///
  /// Any selected properties are ignored: this always returns the node at the
  /// current end of the pattern.
  public func fetchIDs() throws -> [NodeID] {
    var copy = self
    copy.projections = []
    let rows = try requireDatabase().match(copy.cypher)
    return try rows.map { row in
      guard let json = row.json(variable), let snapshot = NodeSnapshot(json: json),
        let id = snapshot.id
      else {
        throw QueryError.notANode(column: variable)
      }
      return id
    }
  }

  /// Runs the query and returns the first row.
  public func first() throws -> Row? {
    try limit(1).fetchRows().first
  }

  /// Runs the query and returns how many rows it matched.
  public func count() throws -> Int {
    try requireDatabase().matchCount(countCypher)
  }
}

extension Database {
  /// Starts a type-safe pattern query rooted at an entity.
  ///
  /// ```swift
  /// let adults = try database.match(Person.self)
  ///   .where(Person.age >= 21)
  ///   .select(Person.name)
  ///   .fetchRows()
  /// ```
  public func match<Root: GraphNode>(_ root: Root.Type) -> Query<Root> {
    Query<Root>(steps: [QueryStep(label: Root.nodeType, variable: "v0")], database: self)
  }
}

extension Query {
  /// Returns a property of the current entity as a result column, addressed by
  /// key path.
  ///
  /// Requires a forwarding member on ``PropertyKeys``; see its documentation.
  public func select<V>(
    _ key: KeyPath<PropertyKeys<Root>, PropertyKey<Root, V>>, as alias: String? = nil
  ) -> Query {
    select(PropertyKeys<Root>()[keyPath: key], as: alias)
  }

  /// Sorts by a property of the current entity, addressed by key path.
  public func orderBy<V>(
    _ key: KeyPath<PropertyKeys<Root>, PropertyKey<Root, V>>,
    _ direction: SortDirection = .ascending
  ) -> Query {
    orderBy(PropertyKeys<Root>()[keyPath: key], direction)
  }

  /// Adds a comparison on a property of the current entity, addressed by key
  /// path.
  ///
  /// ```swift
  /// try database.match(Person.self).where(\.age, .greaterThanOrEqual, 21)
  /// ```
  public func `where`<V: ValueRepresentable>(
    _ key: KeyPath<PropertyKeys<Root>, PropertyKey<Root, V>>,
    _ comparison: Predicate.Comparison,
    _ value: V
  ) -> Query {
    let property = PropertyKeys<Root>()[keyPath: key]
    return self.where(
      Predicate(.comparison(property: property.name, comparison, value.latticeValue)))
  }
}
