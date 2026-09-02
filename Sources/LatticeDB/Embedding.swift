import Foundation
import LatticeBridge

/// Text-to-vector conversion supplied by the native engine.
///
/// Embeddings produced here are the input to
/// ``Transaction/setVector(_:forKey:onNode:)`` and
/// ``Database/vectorSearch(_:limit:efSearch:)``. Nothing requires you to use
/// them: a vector from any source works as long as its width matches
/// ``DatabaseConfiguration/vectorDimensions``.
public enum Embedding {
  /// Returns a deterministic hash embedding of `text`.
  ///
  /// This needs no external service and always returns the same vector for the
  /// same text, which makes it useful for tests and for offline indexing. It
  /// encodes term overlap rather than meaning, so it retrieves far worse than a
  /// learned model on paraphrases.
  ///
  /// - Parameters:
  ///   - text: The text to embed.
  ///   - dimensions: The vector width to produce.
  public static func hash(_ text: String, dimensions: UInt16 = 128) throws -> [Float] {
    var vector: UnsafeMutablePointer<Float>?
    var produced: UInt32 = 0
    try text.withCString {
      try check(lattice_bridge_hash_embed($0, dimensions, &vector, &produced))
    }
    return consume(vector, produced)
  }
}

/// The request shape an embedding endpoint expects.
public enum EmbeddingAPIFormat: Int32, Sendable {
  /// The Ollama `/api/embeddings` shape.
  case ollama = 0
  /// The OpenAI `/v1/embeddings` shape, which many providers reimplement.
  case openAI = 1
}

/// How to reach an HTTP embedding service.
public struct EmbeddingConfiguration: Sendable {
  /// The endpoint URL.
  public var endpoint: String

  /// The model name sent with each request.
  public var model: String

  /// The request shape the endpoint expects.
  public var apiFormat: EmbeddingAPIFormat

  /// A bearer token, or `nil` when the endpoint needs no authentication.
  public var apiKey: String?

  /// The per-request timeout, or `nil` for the engine default of 30 seconds.
  public var timeout: Duration?

  public init(
    endpoint: String, model: String, apiFormat: EmbeddingAPIFormat = .openAI,
    apiKey: String? = nil, timeout: Duration? = nil
  ) {
    self.endpoint = endpoint
    self.model = model
    self.apiFormat = apiFormat
    self.apiKey = apiKey
    self.timeout = timeout
  }
}

/// A client for an HTTP embedding service.
///
/// ``embed(_:)`` blocks on the network for as long as
/// ``EmbeddingConfiguration/timeout`` allows, so do not call it inside a write
/// transaction: the transaction holds its lock for the whole request. Embed
/// first, then open the transaction to store the vector.
public final class EmbeddingClient {
  private var handle: OpaquePointer?

  /// Creates a client for the service described by `configuration`.
  public init(_ configuration: EmbeddingConfiguration) throws {
    var result: OpaquePointer?
    let milliseconds = configuration.timeout.map { UInt32(clamping: $0.milliseconds) } ?? 0
    try configuration.endpoint.withCString { endpoint in
      try configuration.model.withCString { model in
        try withOptionalCString(configuration.apiKey) { apiKey in
          try check(
            lattice_bridge_embedding_client_create(
              endpoint, model, configuration.apiFormat.rawValue, apiKey, milliseconds, &result))
        }
      }
    }
    handle = result
  }

  deinit {
    if let handle { lattice_bridge_embedding_client_free(handle) }
  }

  /// Returns the embedding the service produces for `text`.
  public func embed(_ text: String) throws -> [Float] {
    guard let handle else { throw LatticeError.transactionClosed }
    var vector: UnsafeMutablePointer<Float>?
    var dimensions: UInt32 = 0
    try text.withCString {
      try check(lattice_bridge_embedding_client_embed(handle, $0, &vector, &dimensions))
    }
    return consume(vector, dimensions)
  }
}

/// Copies a native vector into Swift and releases the native allocation.
private func consume(_ vector: UnsafeMutablePointer<Float>?, _ dimensions: UInt32) -> [Float] {
  guard let vector else { return [] }
  defer { lattice_bridge_free_vector(vector, dimensions) }
  return Array(UnsafeBufferPointer(start: vector, count: Int(dimensions)))
}

/// Calls `body` with a C string, or with `nil` when `string` is `nil`.
private func withOptionalCString<T>(
  _ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T
) rethrows -> T {
  guard let string else { return try body(nil) }
  return try string.withCString(body)
}

extension Duration {
  /// This duration in whole milliseconds, rounded toward zero.
  var milliseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
  }
}
