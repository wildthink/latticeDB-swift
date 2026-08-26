import Foundation

/// A failure raised while building or running a ``Cypher`` query.
public enum CypherError: Error, Sendable, Equatable {
  /// An interpolated identifier was empty or contained unsupported characters.
  case invalidIdentifier(String)

  /// Two fragments contributed the same parameter name.
  case duplicateParameter(String)
}

/// A native Cypher query with its bound parameters.
///
/// Build a query with string interpolation. Every interpolated value becomes a
/// bound parameter rather than spliced text, so untrusted input cannot change
/// the shape of the query:
///
/// ```swift
/// let rows = try database.match(
///   "MATCH (p:\(NodeType.person)) WHERE p.name = \(name) RETURN p.name AS name"
/// )
/// // text:       MATCH (p:Person) WHERE p.name = $p0 RETURN p.name AS name
/// // parameters: ["p0": .string(name)]
/// ```
///
/// Interpolating a ``NodeType``, an ``EdgeType``, or a ``PropertyKey`` splices a
/// validated identifier. Splicing arbitrary text requires the explicit
/// `\(raw:)` form, which is the only injection-capable spelling and is therefore
/// easy to review and to search for.
public struct Cypher: Sendable, ExpressibleByStringInterpolation, CustomStringConvertible {
  /// The query text, with `$name` placeholders for every bound parameter.
  public private(set) var text: String

  /// The parameters bound to the query, keyed without the `$` prefix.
  public private(set) var parameters: [String: Value]

  /// The generated parameter names, in the order they were interpolated.
  private var generatedNames: [String]

  /// An error captured while interpolating, rethrown when the query runs.
  private var deferredError: CypherError?

  /// Creates a query from text and explicit parameters.
  ///
  /// The text is used exactly as written; no validation or escaping happens.
  public init(text: String, parameters: [String: Value] = [:]) {
    self.text = text
    self.parameters = parameters
    self.generatedNames = []
    self.deferredError = nil
  }

  public init(stringLiteral value: String) { self.init(text: value) }

  public init(stringInterpolation: StringInterpolation) {
    self.text = stringInterpolation.text
    self.parameters = stringInterpolation.parameters
    self.generatedNames = stringInterpolation.generatedNames
    self.deferredError = stringInterpolation.error
  }

  public var description: String { text }

  /// Returns this query, throwing any error captured while interpolating.
  ///
  /// Interpolation cannot throw, so an invalid identifier is reported here and
  /// by every execution method.
  @discardableResult
  public func validated() throws -> Cypher {
    if let deferredError { throw deferredError }
    return self
  }

  /// Collects interpolated fragments into a query.
  public struct StringInterpolation: StringInterpolationProtocol {
    fileprivate var text = ""
    fileprivate var parameters: [String: Value] = [:]
    fileprivate var generatedNames: [String] = []
    fileprivate var error: CypherError?
    private var reserved: Set<String> = []
    private var counter = 0

    public init(literalCapacity: Int, interpolationCount: Int) {
      text.reserveCapacity(literalCapacity + interpolationCount * 4)
    }

    public mutating func appendLiteral(_ literal: String) { text += literal }

    /// Binds a Swift value as a query parameter.
    public mutating func appendInterpolation(_ value: some ValueRepresentable) {
      bind(value.latticeValue)
    }

    /// Binds a stored scalar as a query parameter.
    public mutating func appendInterpolation(_ value: Value) { bind(value) }

    /// Splices a validated node label.
    public mutating func appendInterpolation(_ type: NodeType) {
      appendIdentifier(type.rawValue)
    }

    /// Splices a validated edge type.
    public mutating func appendInterpolation(_ type: EdgeType) {
      appendIdentifier(type.rawValue)
    }

    /// Splices a validated property name.
    public mutating func appendInterpolation<Owner, V>(_ key: PropertyKey<Owner, V>) {
      appendIdentifier(key.name)
    }

    /// Splices a validated identifier such as a query variable.
    public mutating func appendInterpolation(identifier: String) {
      appendIdentifier(identifier)
    }

    /// Splices text without validation or binding.
    ///
    /// This is the only spelling that can change the shape of a query. Never
    /// pass untrusted input to it.
    public mutating func appendInterpolation(raw: String) { text += raw }

    /// Splices another query, renumbering its generated parameters.
    ///
    /// Renaming follows the fragment's own interpolation order, so a query
    /// assembled from fragments numbers its parameters the same way every run.
    public mutating func appendInterpolation(_ fragment: Cypher) {
      var renamed: [String: String] = [:]
      for name in fragment.generatedNames {
        let replacement = nextParameterName()
        renamed[name] = replacement
        generatedNames.append(replacement)
      }
      for (name, value) in fragment.parameters.sorted(by: { $0.key < $1.key }) {
        guard let target = renamed[name] else {
          if parameters[name] != nil {
            error = error ?? .duplicateParameter(name)
            continue
          }
          parameters[name] = value
          continue
        }
        parameters[target] = value
      }
      text += Cypher.rename(parameters: renamed, in: fragment.text)
      error = error ?? fragment.deferredError
    }

    private mutating func appendIdentifier(_ identifier: String) {
      guard isSimpleIdentifier(identifier) else {
        error = error ?? .invalidIdentifier(identifier)
        return
      }
      text += identifier
    }

    private mutating func bind(_ value: Value) {
      let name = nextParameterName()
      parameters[name] = value
      generatedNames.append(name)
      text += "$\(name)"
    }

    private mutating func nextParameterName() -> String {
      while true {
        let name = "p\(counter)"
        counter += 1
        if parameters[name] == nil, !reserved.contains(name) {
          reserved.insert(name)
          return name
        }
      }
    }
  }

  /// Rewrites `$old` placeholders to their replacements.
  ///
  /// Only generated names are rewritten, and generated names are always `p`
  /// followed by digits.
  private static func rename(parameters renamed: [String: String], in text: String) -> String {
    guard !renamed.isEmpty else { return text }
    var output = ""
    output.reserveCapacity(text.count)
    var rest = Substring(text)
    while let dollar = rest.firstIndex(of: "$") {
      output += rest[..<dollar]
      let afterDollar = rest.index(after: dollar)
      let nameEnd =
        rest[afterDollar...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") }
        ?? rest.endIndex
      let name = String(rest[afterDollar..<nameEnd])
      output += "$" + (renamed[name] ?? name)
      rest = rest[nameEnd...]
    }
    output += rest
    return output
  }
}

/// Returns whether `identifier` is a bare alphanumeric or underscore identifier.
func isSimpleIdentifier(_ identifier: String) -> Bool {
  !identifier.isEmpty
    && identifier.unicodeScalars.allSatisfy {
      $0 == "_" || CharacterSet.alphanumerics.contains($0)
    }
}
