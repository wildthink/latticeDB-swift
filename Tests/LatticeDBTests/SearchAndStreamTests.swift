import Foundation
import Testing

@testable import LatticeDB

/// Runs `body` with a database at a fresh temporary path, removed afterwards.
private func withDatabase<T>(
  configuration: DatabaseConfiguration = .init(), _ body: (Database) throws -> T
) throws -> T {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("latticedb-\(UUID().uuidString).db")
    .path
  defer { try? FileManager.default.removeItem(atPath: path) }
  return try body(try Database(path: path, configuration: configuration))
}

// MARK: - Full-text search

@Test func fullTextSearchRanksDeclaredIndex() throws {
  try withDatabase { database in
    try database.createNodeIndex(label: "Article", property: "id")
    try database.createFullTextIndex(label: "Article", property: "body")
    #expect(try database.fullTextIndexExists(label: "Article", property: "body"))

    let fox = try database.write { transaction -> NodeID in
      let fox = try transaction.createNode(label: "Article")
      try transaction.setProperty(
        "body", onNode: fox, to: .string("the quick brown fox jumps over the lazy dog"))
      let kiln = try transaction.createNode(label: "Article")
      try transaction.setProperty(
        "body", onNode: kiln, to: .string("a kiln fires clay at high temperature"))
      return fox
    }

    let matches = try database.fullTextSearch("fox", label: "Article", property: "body")
    #expect(matches.map(\.node) == [fox])
    #expect(matches[0].score > 0)
  }
}

@Test func fullTextSearchToleratesTyposWhenFuzzy() throws {
  try withDatabase { database in
    try database.createFullTextIndex(label: "Article", property: "body")
    try database.write { transaction in
      let node = try transaction.createNode(label: "Article")
      try transaction.setProperty("body", onNode: node, to: .string("embeddings and retrieval"))
    }

    #expect(try database.fullTextSearch("embeddigns", label: "Article", property: "body").isEmpty)
    let fuzzy = try database.fullTextSearch(
      "embeddigns", label: "Article", property: "body", fuzzy: .default)
    #expect(fuzzy.count == 1)
  }
}

@Test func fullTextSearchInTransactionSeesUncommittedText() throws {
  try withDatabase { database in
    try database.createFullTextIndex(label: "Note", property: "text")
    try database.write { transaction in
      let node = try transaction.createNode(label: "Note")
      try transaction.setProperty("text", onNode: node, to: .string("uncommitted marmalade"))
      let matches = try transaction.fullTextSearch("marmalade", label: "Note", property: "text")
      #expect(matches.map(\.node) == [node])
    }
  }
}

@Test func fullTextSearchWithoutIndexIsAnError() throws {
  try withDatabase { database in
    #expect(throws: LatticeError.self) {
      try database.fullTextSearch("anything", label: "Article", property: "body")
    }
  }
}

@Test func fullTextIndexCanBeDropped() throws {
  try withDatabase { database in
    try database.createFullTextIndex(label: "Article", property: "body")
    try database.dropFullTextIndex(label: "Article", property: "body")
    #expect(try !database.fullTextIndexExists(label: "Article", property: "body"))
  }
}

// MARK: - Vector search

@Test func vectorSearchReturnsNearestNeighborFirst() throws {
  try withDatabase(configuration: .init(vectorDimensions: 4)) { database in
    let near = try database.write { transaction -> NodeID in
      let near = try transaction.createNode(label: "Point")
      try transaction.setVector([1, 0, 0, 0], forKey: "embedding", onNode: near)
      let far = try transaction.createNode(label: "Point")
      try transaction.setVector([0, 0, 0, 1], forKey: "embedding", onNode: far)
      return near
    }

    let matches = try database.vectorSearch([1, 0, 0, 0], limit: 2)
    #expect(matches.count == 2)
    #expect(matches[0].node == near)
    #expect(matches[0].distance <= matches[1].distance)
  }
}

@Test func vectorSearchInTransactionSeesUncommittedVectors() throws {
  try withDatabase(configuration: .init(vectorDimensions: 4)) { database in
    try database.write { transaction in
      let node = try transaction.createNode(label: "Point")
      try transaction.setVector([0, 1, 0, 0], forKey: "embedding", onNode: node)
      #expect(try transaction.vectorSearch([0, 1, 0, 0], limit: 1).map(\.node) == [node])
    }
  }
}

@Test func emptyVectorIsRejectedBeforeReachingTheEngine() throws {
  try withDatabase(configuration: .init(vectorDimensions: 4)) { database in
    #expect(throws: VectorError.invalidDimensions(0)) { try database.vectorSearch([]) }
  }
}

// MARK: - Embeddings

@Test func hashEmbeddingIsDeterministicAndSized() throws {
  let first = try Embedding.hash("evidence-backed memory", dimensions: 64)
  let second = try Embedding.hash("evidence-backed memory", dimensions: 64)
  let other = try Embedding.hash("something else entirely", dimensions: 64)
  #expect(first.count == 64)
  #expect(first == second)
  #expect(first != other)
}

@Test func hashEmbeddingRoundTripsThroughVectorSearch() throws {
  try withDatabase(configuration: .init(vectorDimensions: 64)) { database in
    let target = try database.write { transaction -> NodeID in
      let target = try transaction.createNode(label: "Doc")
      try transaction.setVector(
        try Embedding.hash("swift package manager", dimensions: 64), forKey: "embedding",
        onNode: target)
      let other = try transaction.createNode(label: "Doc")
      try transaction.setVector(
        try Embedding.hash("sourdough starter", dimensions: 64), forKey: "embedding", onNode: other)
      return target
    }

    let query = try Embedding.hash("swift package manager", dimensions: 64)
    #expect(try database.vectorSearch(query, limit: 1).map(\.node) == [target])
  }
}

// MARK: - Durable streams

@Test func streamPublishAssignsIncreasingSequences() throws {
  try withDatabase { database in
    let sequences = try database.write { transaction in
      [
        try transaction.publish(.string("first"), to: "audit"),
        try transaction.publish(.integer(2), to: "audit", kind: "count"),
      ]
    }
    #expect(sequences[0] < sequences[1])
    #expect(try database.lastSequence(ofStream: "audit") == sequences[1])

    let records = try database.readStream("audit")
    #expect(records.count == 2)
    #expect(
      records[0]
        == StreamRecord(sequence: sequences[0], kind: "message", payload: .string("first")))
    #expect(records[1] == StreamRecord(sequence: sequences[1], kind: "count", payload: .integer(2)))
  }
}

@Test func streamReadResumesAfterACursor() throws {
  try withDatabase { database in
    let sequences = try database.write { transaction in
      try (1...3).map { try transaction.publish(.integer(Int64($0)), to: "jobs") }
    }
    let tail = try database.readStream("jobs", after: sequences[0])
    #expect(tail.map(\.sequence) == Array(sequences[1...]))
    #expect(try database.readStream("jobs", limit: 1).map(\.payload) == [.integer(1)])
  }
}

@Test func streamOffsetsAreCommittedByConsumers() throws {
  try withDatabase { database in
    let last = try database.write { transaction in
      try (1...3).map { try transaction.publish(.integer(Int64($0)), to: "jobs") }.last!
    }
    #expect(try database.streamOffset("jobs", consumer: "worker") == nil)

    try database.write { try $0.setStreamOffset(last, stream: "jobs", consumer: "worker") }
    #expect(try database.streamOffset("jobs", consumer: "worker") == last)

    let resumed = try database.readStream(
      "jobs", after: try database.streamOffset("jobs", consumer: "worker") ?? 0)
    #expect(resumed.isEmpty)
  }
}

@Test func streamTrimDiscardsRecordsThroughASequence() throws {
  try withDatabase { database in
    let sequences = try database.write { transaction in
      try (1...3).map { try transaction.publish(.integer(Int64($0)), to: "jobs") }
    }
    try database.write { try $0.trimStream("jobs", through: sequences[1]) }
    #expect(try database.readStream("jobs").map(\.sequence) == [sequences[2]])
  }
}

@Test func streamPayloadsRoundTripEveryScalar() throws {
  try withDatabase { database in
    let payloads: [Value] = [.null, .bool(true), .integer(-7), .double(1.5), .string("ok")]
    try database.write { transaction in
      for payload in payloads { try transaction.publish(payload, to: "values") }
    }
    #expect(try database.readStream("values").map(\.payload) == payloads)
  }
}

@Test func reservedStreamNamesAreRejected() throws {
  try withDatabase { database in
    #expect(throws: StreamError.reservedName("__lattice_internal")) {
      try database.readStream("__lattice_internal")
    }
    #expect(throws: StreamError.reservedName("__lattice_internal")) {
      try database.write { try $0.publish(.null, to: "__lattice_internal") }
    }
  }
}
