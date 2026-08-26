import Foundation

/// A failure raised while reading a query result.
public enum QueryError: Error, Sendable, Equatable {
  /// The result could not be parsed as the expected JSON shape.
  case malformedResult(String)

  /// The named column is not present in the row.
  case missingColumn(String)

  /// A column's value could not be converted to the requested Swift type.
  case valueTypeMismatch(column: String, expected: String)

  /// A column did not hold a node.
  case notANode(column: String)

  /// A query built without a database was asked to run.
  case detachedQuery
}

/// A JSON value returned by a query.
///
/// Query results are JSON today; this type is the boundary where that fact is
/// contained. Scalars project into ``Value`` through ``scalar``.
public enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// The stored scalar this value represents, or `nil` for arrays and objects.
  ///
  /// The native engine prints whole doubles without a fractional part, so a
  /// stored `2.0` arrives as ``integer(_:)``. `Double` accepts both kinds.
  public var scalar: Value? {
    switch self {
    case .null: .null
    case .bool(let value): .bool(value)
    case .integer(let value): .integer(value)
    case .double(let value): .double(value)
    case .string(let value): .string(value)
    case .array, .object: nil
    }
  }

  /// The members of an object value.
  public var object: [String: JSONValue]? {
    guard case .object(let members) = self else { return nil }
    return members
  }

  /// The elements of an array value.
  public var array: [JSONValue]? {
    guard case .array(let elements) = self else { return nil }
    return elements
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// One row of a query result, keyed by returned column name.
public struct Row: Sendable, Equatable {
  /// The row's columns.
  public let columns: [String: JSONValue]

  /// Creates a row from decoded columns.
  public init(columns: [String: JSONValue]) { self.columns = columns }

  /// The column names, sorted.
  ///
  /// JSON objects carry no order, so the engine's column order is not preserved.
  public var columnNames: [String] { columns.keys.sorted() }

  /// Returns a column's scalar, or `nil` when it is absent or not a scalar.
  public subscript(column: String) -> Value? { columns[column]?.scalar }

  /// Returns a column's raw JSON value.
  public func json(_ column: String) -> JSONValue? { columns[column] }

  /// Returns a column converted to a Swift type.
  ///
  /// - Throws: ``QueryError/missingColumn(_:)`` when the column is absent, and
  ///   ``QueryError/valueTypeMismatch(column:expected:)`` when its scalar does
  ///   not convert.
  public func value<V: ValueRepresentable>(_ column: String, as type: V.Type = V.self) throws -> V {
    guard let json = columns[column] else { throw QueryError.missingColumn(column) }
    guard let scalar = json.scalar, let value = V(latticeValue: scalar) else {
      throw QueryError.valueTypeMismatch(column: column, expected: "\(V.self)")
    }
    return value
  }

  /// Returns a typed property from a column, using its declared key.
  public func value<Owner, V: ValueRepresentable>(_ key: PropertyKey<Owner, V>) throws -> V {
    try value(key.name, as: V.self)
  }

  /// Decodes a column into a `Decodable` type.
  public func decode<T: Decodable>(_ type: T.Type, column: String) throws -> T {
    guard let json = columns[column] else { throw QueryError.missingColumn(column) }
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
  }

  /// Decodes the whole row into a `Decodable` type.
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(JSONValue.object(columns)))
  }

  /// Returns a column holding a node.
  ///
  /// - Throws: ``QueryError/notANode(column:)`` when the column is not shaped
  ///   like a node.
  public func node(_ column: String) throws -> NodeSnapshot {
    guard let json = columns[column] else { throw QueryError.missingColumn(column) }
    guard let snapshot = NodeSnapshot(json: json) else {
      throw QueryError.notANode(column: column)
    }
    return snapshot
  }
}

/// A node as returned by a query.
///
/// The native result encoding for a returned node is a JSON object; this type
/// reads the shapes that encoding can take without assuming a single one, and
/// treats every member that is not `id` or `labels` as a property.
public struct NodeSnapshot: Sendable, Equatable {
  /// The node identifier, when the result carried one.
  public let id: NodeID?

  /// The node's labels.
  public let labels: [NodeType]

  /// The node's scalar properties.
  public let properties: [String: Value]

  /// Creates a snapshot.
  public init(id: NodeID?, labels: [NodeType] = [], properties: [String: Value] = [:]) {
    self.id = id
    self.labels = labels
    self.properties = properties
  }

  /// Creates a snapshot from a returned JSON value, or `nil` when the value is
  /// neither a node object nor a bare node identifier.
  public init?(json: JSONValue) {
    if case .integer(let value) = json, value >= 0 {
      self.init(id: NodeID(value))
      return
    }
    guard let members = json.object else { return nil }

    var id: NodeID?
    if case .integer(let value)? = members["id"], value >= 0 { id = NodeID(value) }

    var labels: [NodeType] = []
    switch members["labels"] {
    case .array(let elements)?:
      labels = elements.compactMap {
        guard case .string(let label) = $0 else { return nil }
        return NodeType(label)
      }
    case .string(let joined)?:
      labels = joined.split(separator: ",").map { NodeType(String($0)) }
    default:
      break
    }

    var properties: [String: Value] = [:]
    let nested = members["properties"]?.object
    if let nested {
      for (name, value) in nested {
        if let scalar = value.scalar { properties[name] = scalar }
      }
    } else {
      for (name, value) in members where !reservedNodeKeys.contains(name) {
        if let scalar = value.scalar { properties[name] = scalar }
      }
    }

    guard id != nil || nested != nil || !labels.isEmpty else { return nil }
    self.init(id: id, labels: labels, properties: properties)
  }

  /// Returns a typed property of this node.
  public func value<Owner, V: ValueRepresentable>(_ key: PropertyKey<Owner, V>) -> V? {
    properties[key.name].flatMap(V.init(latticeValue:))
  }
}

private let reservedNodeKeys: Set<String> = ["id", "labels"]

/// Parses the JSON array returned by the native bridge into rows.
func parseRows(_ json: String) throws -> [Row] {
  let data = Data(json.utf8)
  do {
    let decoded = try JSONDecoder().decode([JSONValue].self, from: data)
    return try decoded.map { element in
      guard let members = element.object else {
        throw QueryError.malformedResult("expected an object per row")
      }
      return Row(columns: members)
    }
  } catch let error as QueryError {
    throw error
  } catch {
    throw QueryError.malformedResult("\(error)")
  }
}
