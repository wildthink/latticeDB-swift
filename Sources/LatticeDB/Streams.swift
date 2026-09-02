import Foundation
import LatticeBridge

/// One record read from a durable stream.
public struct StreamRecord: Sendable, Equatable {
  /// The record's position in its stream. Sequences increase monotonically and
  /// are never reused, so a consumer resumes by reading after the last sequence
  /// it handled.
  public let sequence: UInt64

  /// The publisher-assigned record kind, defaulting to `message`.
  public let kind: String

  /// The published payload.
  public let payload: Value

  public init(sequence: UInt64, kind: String, payload: Value) {
    self.sequence = sequence
    self.kind = kind
    self.payload = payload
  }
}

/// An error raised before a stream operation reaches the native engine.
public enum StreamError: Error, Sendable, Equatable {
  /// A stream name began with `__lattice_`, which the engine reserves.
  case reservedName(String)
}

extension Transaction {
  /// Publishes `payload` to `stream` and returns the sequence it was assigned.
  ///
  /// A stream is created by its first publish. The returned sequence is durable
  /// only once this transaction commits.
  ///
  /// - Parameters:
  ///   - payload: The value to publish.
  ///   - stream: The stream name, which must not begin with `__lattice_`.
  ///   - kind: A publisher-assigned record kind, defaulting to `message`.
  @discardableResult
  public func publish(_ payload: Value, to stream: String, kind: String? = nil) throws -> UInt64 {
    try validate(stream)
    return try withHandle { handle in
      var sequence: UInt64 = 0
      let code = stream.withCString { stream in
        withOptionalCString(kind) { kind in
          withScalarArguments(payload) { type, integer, real, boolean, string in
            lattice_bridge_stream_publish(
              handle, stream, kind, type, integer, real, boolean, string, &sequence)
          }
        }
      }
      try check(code)
      return sequence
    }
  }

  /// Records that `consumer` has handled `stream` through `sequence`.
  ///
  /// Reading does not advance an offset. Commit the offset in the same
  /// transaction as the work it covers, and the two stay consistent even if the
  /// process stops between them.
  public func setStreamOffset(_ sequence: UInt64, stream: String, consumer: String) throws {
    try validate(stream)
    try withHandle { handle in
      try stream.withCString { stream in
        try consumer.withCString { consumer in
          try check(lattice_bridge_stream_set_offset(handle, stream, consumer, sequence))
        }
      }
    }
  }

  /// Discards records in `stream` up to and including `sequence`.
  ///
  /// Trimming is permanent and ignores consumer offsets, so trim only through a
  /// sequence every consumer has already passed.
  public func trimStream(_ stream: String, through sequence: UInt64) throws {
    try validate(stream)
    try withHandle { handle in
      try stream.withCString { stream in
        try check(lattice_bridge_stream_trim(handle, stream, sequence))
      }
    }
  }
}

extension Database {
  /// Reads up to `limit` records published to `stream` after `sequence`.
  ///
  /// Reading does not advance any consumer offset; commit one with
  /// ``Transaction/setStreamOffset(_:stream:consumer:)``.
  ///
  /// - Parameters:
  ///   - stream: The stream to read.
  ///   - sequence: The cursor to read after. Pass `0` to read from the start.
  ///   - limit: The greatest number of records to return.
  ///   - timeout: How long to wait for a record when none is available. Only a
  ///     commit from this process wakes the wait, so a reader in another
  ///     process should poll rather than rely on it.
  public func readStream(
    _ stream: String, after sequence: UInt64 = 0, limit: Int = 100, timeout: Duration = .zero
  ) throws -> [StreamRecord] {
    try validate(stream)
    guard let handle else { throw LatticeError.transactionClosed }
    var batch: OpaquePointer?
    var count = 0
    try stream.withCString {
      try check(
        lattice_bridge_stream_read(
          handle, $0, sequence, limit, UInt32(clamping: timeout.milliseconds), &batch, &count))
    }
    guard let batch else { return [] }
    defer { lattice_bridge_stream_batch_free(batch) }
    return try (0..<count).map { try record(batch, at: $0) }
  }

  /// Returns the sequence `consumer` last committed for `stream`, or `nil` when
  /// it has committed none.
  public func streamOffset(_ stream: String, consumer: String) throws -> UInt64? {
    try validate(stream)
    guard let handle else { throw LatticeError.transactionClosed }
    var exists = false
    var sequence: UInt64 = 0
    try stream.withCString { stream in
      try consumer.withCString { consumer in
        try check(lattice_bridge_stream_offset(handle, stream, consumer, &exists, &sequence))
      }
    }
    return exists ? sequence : nil
  }

  /// Returns the newest sequence published to `stream`, or `0` when it holds no
  /// records.
  public func lastSequence(ofStream stream: String) throws -> UInt64 {
    try validate(stream)
    guard let handle else { throw LatticeError.transactionClosed }
    var sequence: UInt64 = 0
    try stream.withCString {
      try check(lattice_bridge_stream_last_sequence(handle, $0, &sequence))
    }
    return sequence
  }

  private func record(_ batch: OpaquePointer, at index: Int) throws -> StreamRecord {
    var sequence: UInt64 = 0
    var kind: UnsafeMutablePointer<CChar>?
    var type: Int32 = 0
    var integer: Int64 = 0
    var real = 0.0
    var boolean = false
    var string: UnsafeMutablePointer<CChar>?
    try check(
      lattice_bridge_stream_batch_get(
        batch, index, &sequence, &kind, &type, &integer, &real, &boolean, &string))
    defer {
      if let kind { lattice_bridge_free_buffer(kind) }
      if let string { lattice_bridge_free_buffer(string) }
    }
    let payload: Value
    switch type {
    case 0: payload = .null
    case 1: payload = .bool(boolean)
    case 2: payload = .integer(integer)
    case 3: payload = .double(real)
    case 4: payload = .string(string.map { String(cString: $0) } ?? "")
    default:
      throw QueryError.malformedResult("stream payload at sequence \(sequence) is not a scalar")
    }
    return StreamRecord(
      sequence: sequence, kind: kind.map { String(cString: $0) } ?? "", payload: payload)
  }
}

/// Rejects the stream-name prefix the engine reserves for its own streams,
/// which it would otherwise refuse with an opaque native code.
private func validate(_ stream: String) throws {
  guard !stream.hasPrefix("__lattice_") else { throw StreamError.reservedName(stream) }
}

/// Calls `body` with a C string, or with `nil` when `string` is `nil`.
private func withOptionalCString<T>(
  _ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T
) rethrows -> T {
  guard let string else { return try body(nil) }
  return try string.withCString(body)
}
