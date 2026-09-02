import Foundation
import LatticeDB

/// Something that turns text into a vector for similarity search.
///
/// A store with an embedder writes a vector alongside every record it stores, so
/// ``SearchMode/vector`` and ``SearchMode/hybrid`` retrieval have something to
/// search. Without one, retrieval is lexical and everything else still works.
public protocol TextEmbedder: Sendable {
  /// The width of the vectors this produces. A store's database must be opened
  /// with a matching `DatabaseConfiguration.vectorDimensions`.
  var dimensions: UInt16 { get }

  /// Returns the vector for `text`.
  func embed(_ text: String) throws -> [Float]
}

/// The engine's built-in hash embedder: deterministic, offline, and free.
///
/// It encodes term overlap rather than meaning, so it will not connect a
/// paraphrase to its original the way a learned model does. Its value is that it
/// never varies — the same corpus always produces the same index — which makes it
/// the right choice for tests, for reproducible fixtures, and as the baseline a
/// learned embedder has to beat.
public struct HashEmbedder: TextEmbedder {
  public let dimensions: UInt16

  public init(dimensions: UInt16 = 128) {
    self.dimensions = dimensions
  }

  public func embed(_ text: String) throws -> [Float] {
    try Embedding.hash(text, dimensions: dimensions)
  }
}

/// Uses an HTTP embedding service as a store's embedder.
///
/// `EmbeddingClient.embed(_:)` blocks on the network, and a store embeds
/// *before* it opens its write transaction precisely so that wait does not hold
/// a database lock. The `dimensions` you give must match what the service
/// returns; a mismatch surfaces as a native error on the first write.
///
/// Calls are serialized by a lock rather than issued concurrently. The native
/// client makes no documented thread-safety promise, and one embedding per
/// stored record is not a rate worth racing for.
public final class RemoteEmbedder: TextEmbedder, @unchecked Sendable {
  public let dimensions: UInt16
  private let client: EmbeddingClient
  private let lock = NSLock()

  public init(client: EmbeddingClient, dimensions: UInt16) {
    self.client = client
    self.dimensions = dimensions
  }

  public func embed(_ text: String) throws -> [Float] {
    lock.lock()
    defer { lock.unlock() }
    return try client.embed(text)
  }
}
