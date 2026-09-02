import Foundation
import LatticeDB

// MARK: - Model

/// Where a unit of deferred work has got to.
public enum JobState: String, Sendable, Codable {
  /// Waiting to be leased.
  case pending

  /// Claimed by a worker, with a lease that expires.
  case leased

  /// Finished successfully.
  case completed

  /// Given up on after ``MemoryStore/maximumJobAttempts`` tries.
  case failed
}

/// One unit of deferred work, materialized from a durable stream record.
///
/// A job is operational rather than remembered: it is not evidence, nothing
/// cites it, and it takes no part in scope, valid time, or forgetting. It exists
/// so that work triggered by a write survives the process that triggered it.
public struct Job: Sendable, Equatable, Identifiable {
  /// The stable identifier assigned when this was materialized.
  public let id: RecordID

  /// The stream the triggering record came from.
  public var stream: String

  /// That record's position in the stream.
  public var sequence: UInt64

  /// The worker this job belongs to.
  ///
  /// One stream record materializes one job *per worker*, so several independent
  /// consumers can each do their own work from the same event.
  public var worker: String

  /// The kind the stream record was published with, such as
  /// ``MemoryStore/EventKind/evidenceRecorded``.
  public var kind: String

  /// The stream record's payload — for the store's own events, the identifier of
  /// the record that changed.
  public var payload: Value

  /// Where the job has got to.
  public var state: JobState

  /// How many times it has been leased.
  public var attempts: Int

  /// When the current lease runs out, or `nil` when it is not leased.
  public var leaseExpiresAt: Date?

  /// What went wrong the last time, when something did.
  public var lastError: String?

  /// When this job was materialized.
  public var createdAt: Date
}

/// What one pass of ``MemoryStore/run(worker:count:lease:_:)`` did.
public struct JobRunReport: Sendable, Equatable {
  /// Jobs whose handler returned normally.
  public let completed: [RecordID]

  /// Jobs whose handler threw, with the error text for each. A job here may
  /// still be ``JobState/pending`` for another attempt.
  public let failed: [(job: RecordID, error: String)]

  /// Whether anything was leased at all.
  public var isEmpty: Bool { completed.isEmpty && failed.isEmpty }

  public static func == (lhs: JobRunReport, rhs: JobRunReport) -> Bool {
    lhs.completed == rhs.completed && lhs.failed.map(\.job) == rhs.failed.map(\.job)
      && lhs.failed.map(\.error) == rhs.failed.map(\.error)
  }
}

extension MemoryStore {
  /// The kinds the store publishes its own events with.
  public enum EventKind {
    /// Evidence was recorded. The payload is its identifier.
    public static let evidenceRecorded = "evidence.recorded"

    /// Evidence was forgotten. The payload is its identifier, which for a
    /// tombstone still resolves and for an erasure no longer does.
    public static let evidenceForgotten = "evidence.forgotten"
  }

  // MARK: - Materializing

  /// Turns stream records into jobs for `worker`, one per record.
  ///
  /// Reading starts after the offset `worker` last committed for `stream`, and
  /// the new offset is committed in the same transaction as the jobs it covers.
  /// If the process stops mid-way, both roll back and the next call reads the
  /// same records again.
  ///
  /// That still leaves a race between two materializers running at once, so each
  /// job also carries a unique `{stream, sequence, worker}` key and a duplicate
  /// is skipped rather than written. Materializing twice is a no-op, which is
  /// what makes it safe to run on a timer.
  ///
  /// - Parameters:
  ///   - stream: The stream to read.
  ///   - worker: The worker to create jobs for, and whose offset to advance.
  ///   - limit: The most records to read in one pass.
  /// - Returns: The jobs created, which excludes any that already existed.
  @discardableResult
  public func materialize(stream: String, worker: String, limit: Int = 500) throws -> [Job] {
    let cursor = try database.streamOffset(stream, consumer: worker) ?? 0
    let records = try database.readStream(stream, after: cursor, limit: limit)
    guard !records.isEmpty else { return [] }

    let now = clock()
    return try database.write { transaction in
      var created: [Job] = []
      for record in records {
        let key = jobKey(stream: stream, sequence: record.sequence, worker: worker)
        guard try jobNode(key: key, in: transaction) == nil else { continue }
        let job = Job(
          id: RecordID.generate(prefix: "jb", now: now), stream: stream,
          sequence: record.sequence, worker: worker, kind: record.kind, payload: record.payload,
          state: .pending, attempts: 0, leaseExpiresAt: nil, lastError: nil, createdAt: now)
        try write(job, key: key, in: transaction)
        created.append(job)
      }
      if let last = records.last {
        try transaction.setStreamOffset(last.sequence, stream: stream, consumer: worker)
      }
      return created
    }
  }

  // MARK: - Leasing

  /// Claims up to `count` jobs for `worker` and returns them.
  ///
  /// A lease is a deadline, not a lock. A job whose lease has expired is
  /// available again, so a worker that crashes mid-job does not strand it —
  /// which is also why a handler must tolerate running twice.
  ///
  /// Leasing increments ``Job/attempts``. A job that reaches
  /// ``maximumJobAttempts`` without completing becomes ``JobState/failed`` and
  /// is not leased again.
  public func lease(
    worker: String, count: Int = 1, duration: Duration = .seconds(60)
  ) throws -> [Job] {
    let now = clock()
    let expiry = now.addingTimeInterval(duration.seconds)
    return try database.write { transaction in
      var leased: [Job] = []
      for node in try transaction.nodeIDs(
        label: Labels.job, property: Keys.worker, equals: .string(worker))
      {
        guard leased.count < count else { break }
        var job = try readJob(node, in: transaction)
        switch job.state {
        case .pending: break
        case .leased:
          // An expired lease means the previous holder is gone.
          guard let expires = job.leaseExpiresAt, expires <= now else { continue }
        case .completed, .failed: continue
        }
        job.attempts += 1
        if job.attempts > maximumJobAttempts {
          job.state = .failed
          job.leaseExpiresAt = nil
          try write(job, key: jobKey(job), in: transaction)
          continue
        }
        job.state = .leased
        job.leaseExpiresAt = expiry
        try write(job, key: jobKey(job), in: transaction)
        leased.append(job)
      }
      return leased
    }
  }

  /// Marks a job finished.
  ///
  /// - Throws: ``MemoryError/unknownRecord(_:)`` when no such job exists.
  public func complete(_ id: RecordID) throws {
    try update(id) { job in
      job.state = .completed
      job.leaseExpiresAt = nil
      job.lastError = nil
    }
  }

  /// Records a failed attempt.
  ///
  /// The job returns to ``JobState/pending`` for another try, or becomes
  /// ``JobState/failed`` once it has used up ``maximumJobAttempts``.
  ///
  /// - Throws: ``MemoryError/unknownRecord(_:)`` when no such job exists.
  public func fail(_ id: RecordID, error: String) throws {
    try update(id) { job in
      job.state = job.attempts >= maximumJobAttempts ? .failed : .pending
      job.leaseExpiresAt = nil
      job.lastError = error
    }
  }

  /// Returns a failed job to the queue with its attempt count reset.
  ///
  /// For after you have fixed whatever was breaking it.
  ///
  /// - Throws: ``MemoryError/unknownRecord(_:)`` when no such job exists.
  public func retry(_ id: RecordID) throws {
    try update(id) { job in
      job.state = .pending
      job.attempts = 0
      job.leaseExpiresAt = nil
    }
  }

  /// Leases jobs, runs `body` over each, and records the outcome.
  ///
  /// A handler that returns normally completes its job; one that throws fails
  /// it, and the error text is kept on the job. One handler throwing does not
  /// stop the pass.
  ///
  /// Handlers must be **idempotent**. Delivery is at-least-once: a lease that
  /// expires mid-flight makes the job available again, and the work may run
  /// twice.
  @discardableResult
  public func run(
    worker: String, count: Int = 1, lease duration: Duration = .seconds(60),
    _ body: (Job) throws -> Void
  ) throws -> JobRunReport {
    var completed: [RecordID] = []
    var failed: [(job: RecordID, error: String)] = []
    for job in try lease(worker: worker, count: count, duration: duration) {
      do {
        try body(job)
        try complete(job.id)
        completed.append(job.id)
      } catch {
        let text = String(describing: error)
        try fail(job.id, error: text)
        failed.append((job.id, text))
      }
    }
    return JobRunReport(completed: completed, failed: failed)
  }

  // MARK: - Reading

  /// Returns `worker`'s jobs, oldest first.
  ///
  /// - Parameters:
  ///   - worker: The worker whose queue to read.
  ///   - state: One state to restrict to, or `nil` for all of them.
  public func jobs(worker: String, state: JobState? = nil) throws -> [Job] {
    try database.read { transaction in
      try transaction.nodeIDs(
        label: Labels.job, property: Keys.worker, equals: .string(worker)
      )
      .map { try readJob($0, in: transaction) }
      .filter { state == nil || $0.state == state }
      .sorted { ($0.stream, $0.sequence) < ($1.stream, $1.sequence) }
    }
  }

  /// Returns the job with `id`, or `nil`.
  public func job(_ id: RecordID) throws -> Job? {
    try database.read { transaction in
      guard let node = try locate(id, label: Labels.job, in: transaction) else { return nil }
      return try readJob(node, in: transaction)
    }
  }

  /// Deletes completed jobs, and optionally failed ones.
  ///
  /// Jobs accumulate; nothing depends on a finished one. Failed jobs are kept by
  /// default because they are usually the reason you are looking.
  @discardableResult
  public func pruneJobs(worker: String, includingFailed: Bool = false) throws -> Int {
    try database.write { transaction in
      var removed = 0
      for node in try transaction.nodeIDs(
        label: Labels.job, property: Keys.worker, equals: .string(worker))
      {
        let job = try readJob(node, in: transaction)
        guard job.state == .completed || (includingFailed && job.state == .failed) else {
          continue
        }
        try transaction.deleteNode(node)
        removed += 1
      }
      return removed
    }
  }

  // MARK: - Storage

  private func update(_ id: RecordID, _ change: (inout Job) -> Void) throws {
    try database.write { transaction in
      guard let node = try locate(id, label: Labels.job, in: transaction) else {
        throw MemoryError.unknownRecord(id)
      }
      var job = try readJob(node, in: transaction)
      change(&job)
      try write(job, key: jobKey(job), in: transaction)
    }
  }

  private func jobKey(stream: String, sequence: UInt64, worker: String) -> String {
    "\(stream)\u{1F}\(sequence)\u{1F}\(worker)"
  }

  private func jobKey(_ job: Job) -> String {
    jobKey(stream: job.stream, sequence: job.sequence, worker: job.worker)
  }

  private func jobNode(key: String, in transaction: Transaction) throws -> NodeID? {
    try transaction.nodeIDs(
      label: Labels.job, property: Keys.jobKey, equals: .string(key), limit: 1
    ).first
  }

  private func write(_ job: Job, key: String, in transaction: Transaction) throws {
    let node = try jobNode(key: key, in: transaction)
      ?? transaction.createNode(label: Labels.job)
    try transaction.setProperty(Keys.id, onNode: node, to: .string(job.id.rawValue))
    try transaction.setProperty(Keys.jobKey, onNode: node, to: .string(key))
    try transaction.setProperty(Keys.stream, onNode: node, to: .string(job.stream))
    try transaction.setProperty(
      Keys.sequence, onNode: node, to: .integer(Int64(bitPattern: job.sequence)))
    try transaction.setProperty(Keys.worker, onNode: node, to: .string(job.worker))
    try transaction.setProperty(Keys.kind, onNode: node, to: .string(job.kind))
    try transaction.setProperty(Keys.payload, onNode: node, to: job.payload)
    try transaction.setProperty(Keys.state, onNode: node, to: .string(job.state.rawValue))
    try transaction.setProperty(Keys.attempts, onNode: node, to: .integer(Int64(job.attempts)))
    try transaction.setProperty(
      Keys.leaseExpiresAt, onNode: node, to: job.leaseExpiresAt?.latticeValue ?? .null)
    try transaction.setProperty(
      Keys.lastError, onNode: node, to: job.lastError.map { .string($0) } ?? .null)
    try transaction.setProperty(Keys.createdAt, onNode: node, to: job.createdAt.latticeValue)
  }

  func readJob(_ node: NodeID, in transaction: Transaction) throws -> Job {
    func string(_ key: String) throws -> String {
      guard case .string(let value) = try transaction.propertyValue(key, ofNode: node) else {
        return ""
      }
      return value
    }
    func integer(_ key: String) throws -> Int64 {
      guard case .integer(let value) = try transaction.propertyValue(key, ofNode: node) else {
        return 0
      }
      return value
    }
    let id = RecordID(try string(Keys.id))
    guard let state = JobState(rawValue: try string(Keys.state)) else {
      throw MemoryError.malformedRecord(id, "unknown job state")
    }
    var leaseExpiresAt: Date?
    if case .integer(let milliseconds) = try transaction.propertyValue(
      Keys.leaseExpiresAt, ofNode: node)
    {
      leaseExpiresAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
    var lastError: String?
    if case .string(let text) = try transaction.propertyValue(Keys.lastError, ofNode: node) {
      lastError = text
    }
    return Job(
      id: id,
      stream: try string(Keys.stream),
      sequence: UInt64(bitPattern: try integer(Keys.sequence)),
      worker: try string(Keys.worker),
      kind: try string(Keys.kind),
      payload: try transaction.propertyValue(Keys.payload, ofNode: node),
      state: state,
      attempts: Int(try integer(Keys.attempts)),
      leaseExpiresAt: leaseExpiresAt,
      lastError: lastError,
      createdAt: Date(timeIntervalSince1970: Double(try integer(Keys.createdAt)) / 1_000))
  }
}

extension Duration {
  /// This duration in seconds.
  ///
  /// `Duration` measures in attoseconds and `Date` in seconds, so a lease
  /// deadline has to cross between the two.
  var seconds: Double {
    let (whole, attoseconds) = components
    return Double(whole) + Double(attoseconds) / 1e18
  }
}
