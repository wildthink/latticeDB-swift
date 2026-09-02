import Foundation
import LatticeDB
import Testing

@testable import LatticeMemory

private func withStore<T>(_ body: (MemoryStore) throws -> T) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("jobs-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let schema: MemorySchema = ["package.manager": SlotRule(kind: .string, category: "tooling")]
  let store = try MemoryStore(path: path, schema: schema)
  store.eventStream = "memory.events"
  return try body(store)
}

private func at(_ day: Int) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
}

// MARK: - Events

@Test func recordingPublishesAnEventWhenAStreamIsSet() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "something happened")).evidence

    let records = try store.database.readStream("memory.events")
    #expect(records.count == 1)
    #expect(records[0].kind == MemoryStore.EventKind.evidenceRecorded)
    #expect(records[0].payload == .string(evidence.id.rawValue))
  }
}

@Test func forgettingPublishesAnEvent() throws {
  try withStore { store in
    let evidence = try store.record(EvidenceDraft(text: "something happened")).evidence
    try store.forget(.identifiers([evidence.id]))

    let kinds = try store.database.readStream("memory.events").map(\.kind)
    #expect(
      kinds == [
        MemoryStore.EventKind.evidenceRecorded, MemoryStore.EventKind.evidenceForgotten,
      ])
  }
}

@Test func noEventsArePublishedWithoutAStream() throws {
  try withStore { store in
    store.eventStream = nil
    try store.record(EvidenceDraft(text: "something happened"))
    #expect(try store.database.readStream("memory.events").isEmpty)
  }
}

@Test func anEventDoesNotOutliveARolledBackWrite() throws {
  try withStore { store in
    let id = RecordID("fixed")
    try store.record(EvidenceDraft(text: "first", id: id))
    #expect(throws: MemoryError.duplicateIdentifier(id)) {
      try store.record(EvidenceDraft(text: "again", id: id))
    }
    // The refused write rolled back, and its event went with it.
    #expect(try store.database.readStream("memory.events").count == 1)
  }
}

// MARK: - Materializing

@Test func materializingTurnsEventsIntoPendingJobs() throws {
  try withStore { store in
    let first = try store.record(EvidenceDraft(text: "one")).evidence
    try store.record(EvidenceDraft(text: "two"))

    let jobs = try store.materialize(stream: "memory.events", worker: "indexer")
    #expect(jobs.count == 2)
    #expect(jobs.allSatisfy { $0.state == .pending && $0.attempts == 0 })
    #expect(jobs[0].payload == .string(first.id.rawValue))
    #expect(jobs[0].worker == "indexer")
  }
}

@Test func materializingTwiceCreatesNothingNew() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    #expect(try store.materialize(stream: "memory.events", worker: "indexer").count == 1)
    #expect(try store.materialize(stream: "memory.events", worker: "indexer").isEmpty)
    #expect(try store.jobs(worker: "indexer").count == 1)
  }
}

@Test func materializingResumesFromTheWorkersOwnOffset() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")

    try store.record(EvidenceDraft(text: "two"))
    let second = try store.materialize(stream: "memory.events", worker: "indexer")
    #expect(second.count == 1)
    #expect(second[0].sequence > 1)
  }
}

@Test func eachWorkerGetsItsOwnJobForTheSameEvent() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    let indexer = try store.materialize(stream: "memory.events", worker: "indexer")
    let notifier = try store.materialize(stream: "memory.events", worker: "notifier")

    #expect(indexer.count == 1)
    #expect(notifier.count == 1)
    #expect(indexer[0].id != notifier[0].id)
    #expect(indexer[0].sequence == notifier[0].sequence)
  }
}

@Test func materializingAnEmptyStreamDoesNothing() throws {
  try withStore { store in
    let jobs = try store.materialize(stream: "memory.events", worker: "indexer")
    #expect(jobs.isEmpty)
  }
}

// MARK: - Leasing

@Test func leasingClaimsPendingJobsAndCountsAttempts() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    try store.record(EvidenceDraft(text: "two"))
    try store.materialize(stream: "memory.events", worker: "indexer")

    let leased = try store.lease(worker: "indexer", count: 1)
    #expect(leased.count == 1)
    #expect(leased[0].state == .leased)
    #expect(leased[0].attempts == 1)
    #expect(leased[0].leaseExpiresAt != nil)

    // The one already leased is not handed out again.
    let next = try store.lease(worker: "indexer", count: 5)
    #expect(next.count == 1)
    #expect(next[0].id != leased[0].id)
  }
}

@Test func anExpiredLeaseMakesTheJobAvailableAgain() throws {
  try withStore { store in
    store.clock = { at(1) }
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")
    let first = try store.lease(worker: "indexer", duration: .seconds(60))
    #expect(first.count == 1)

    // A worker that crashed mid-job leaves the lease to expire.
    store.clock = { at(2) }
    let reclaimed = try store.lease(worker: "indexer")
    #expect(reclaimed.map(\.id) == first.map(\.id))
    #expect(reclaimed[0].attempts == 2)
  }
}

@Test func leasingIsScopedToOneWorker() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")
    #expect(try store.lease(worker: "notifier").isEmpty)
  }
}

// MARK: - Completing and failing

@Test func runCompletesJobsWhoseHandlerReturns() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")

    var seen: [String] = []
    let report = try store.run(worker: "indexer") { job in seen.append(job.kind) }

    #expect(seen == [MemoryStore.EventKind.evidenceRecorded])
    #expect(report.completed.count == 1)
    #expect(report.failed.isEmpty)
    #expect(try store.jobs(worker: "indexer", state: .completed).count == 1)
    #expect(try store.lease(worker: "indexer").isEmpty)
  }
}

@Test func aThrowingHandlerReturnsTheJobForAnotherAttempt() throws {
  try withStore { store in
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")

    let report = try store.run(worker: "indexer") { _ in throw Boom() }
    #expect(report.completed.isEmpty)
    #expect(report.failed.count == 1)

    let job = try #require(try store.job(report.failed[0].job))
    #expect(job.state == .pending)
    #expect(job.attempts == 1)
    #expect(job.lastError?.contains("Boom") == true)
  }
}

@Test func aJobIsGivenUpOnAfterItsAttemptsRunOut() throws {
  try withStore { store in
    store.maximumJobAttempts = 2
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")

    for _ in 1...2 { try store.run(worker: "indexer") { _ in throw Boom() } }

    let failed = try store.jobs(worker: "indexer", state: .failed)
    #expect(failed.count == 1)
    #expect(failed[0].attempts == 2)
    // A failed job is not handed out again.
    #expect(try store.run(worker: "indexer") { _ in }.isEmpty)
  }
}

@Test func retryingResetsAFailedJob() throws {
  try withStore { store in
    store.maximumJobAttempts = 1
    try store.record(EvidenceDraft(text: "one"))
    try store.materialize(stream: "memory.events", worker: "indexer")
    try store.run(worker: "indexer") { _ in throw Boom() }

    let failed = try #require(try store.jobs(worker: "indexer", state: .failed).first)
    try store.retry(failed.id)

    let job = try #require(try store.job(failed.id))
    #expect(job.state == .pending)
    #expect(job.attempts == 0)
    #expect(try store.run(worker: "indexer") { _ in }.completed == [failed.id])
  }
}

@Test func actingOnAnUnknownJobIsRefused() throws {
  try withStore { store in
    let missing = RecordID("nope")
    #expect(throws: MemoryError.unknownRecord(missing)) { try store.complete(missing) }
    #expect(throws: MemoryError.unknownRecord(missing)) { try store.fail(missing, error: "x") }
    #expect(throws: MemoryError.unknownRecord(missing)) { try store.retry(missing) }
  }
}

// MARK: - Housekeeping

@Test func pruningRemovesFinishedJobs() throws {
  try withStore { store in
    store.maximumJobAttempts = 1
    try store.record(EvidenceDraft(text: "one"))
    try store.record(EvidenceDraft(text: "two"))
    try store.materialize(stream: "memory.events", worker: "indexer")

    try store.run(worker: "indexer") { _ in }
    try store.run(worker: "indexer") { _ in throw Boom() }

    #expect(try store.pruneJobs(worker: "indexer") == 1)
    #expect(try store.jobs(worker: "indexer").map(\.state) == [.failed])

    #expect(try store.pruneJobs(worker: "indexer", includingFailed: true) == 1)
    #expect(try store.jobs(worker: "indexer").isEmpty)
  }
}

// MARK: - End to end

@Test func aWorkerCanDeferRealWorkOffTheWritePath() throws {
  try withStore { store in
    // Records arrive with no embeddings, and a worker adds them afterwards.
    for day in 1...3 {
      try store.record(EvidenceDraft(text: "record \(day)", occurredAt: at(day)))
    }
    try store.materialize(stream: "memory.events", worker: "embedder")

    var embedded: [RecordID] = []
    let report = try store.run(worker: "embedder", count: 10) { job in
      guard case .string(let id) = job.payload else { return }
      guard let evidence = try store.evidence(RecordID(id)) else { return }
      #expect(!evidence.text.isEmpty)
      embedded.append(evidence.id)
    }

    #expect(embedded.count == 3)
    #expect(report.completed.count == 3)
    #expect(try store.jobs(worker: "embedder", state: .pending).isEmpty)
  }
}

private struct Boom: Error {}
