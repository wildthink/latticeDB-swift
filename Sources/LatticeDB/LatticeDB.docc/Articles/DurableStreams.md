# Durable Streams

An append-only log inside the database, for work that should outlive a crash.

## Overview

A stream is an ordered, durable sequence of records stored in the same file as
the graph. Publishing happens inside a write transaction, so a record and the
graph change that produced it commit together or not at all — which is the whole
point. An in-process queue loses its contents when the process stops; a stream
does not.

Streams suit any work you would otherwise hand to a background queue: reindexing
after an import, notifying downstream systems, recording an audit trail, or
deferring an expensive derivation off the write path.

```swift
try database.write { transaction in
  let article = try transaction.createNode(label: "Article")
  try transaction.setProperty("body", onNode: article, to: .string(body))
  try transaction.publish(.integer(Int64(article)), to: "articles.indexed", kind: "created")
}
```

A stream is created by its first publish; there is no separate declaration. Names
beginning with `__lattice_` are reserved by the engine and rejected as
``StreamError/reservedName(_:)``.

## Sequences

Every record gets a sequence number that increases monotonically within its
stream and is never reused. ``Transaction/publish(_:to:kind:)`` returns the
sequence it assigned, though that number is only durable once the transaction
commits.

Sequences are the entire addressing scheme. A consumer reads records after a
cursor, and resumes by remembering the last one it handled:

```swift
let records = try database.readStream("articles.indexed", after: cursor, limit: 100)
for record in records {
  try handle(record.payload)
}
```

Each ``StreamRecord`` carries its sequence, its publisher-assigned `kind`
(defaulting to `message`), and a scalar ``Value`` payload. For anything
structured, encode it to JSON and publish the string.

``Database/lastSequence(ofStream:)`` reports how far a stream has been written,
which makes backlog depth a subtraction.

## Offsets

Reading does not advance anything — a second read with the same cursor returns
the same records. Progress is recorded explicitly, per named consumer:

```swift
let cursor = try database.streamOffset("articles.indexed", consumer: "indexer") ?? 0
let records = try database.readStream("articles.indexed", after: cursor, limit: 100)

try database.write { transaction in
  for record in records { try index(record, in: transaction) }
  if let last = records.last {
    try transaction.setStreamOffset(last.sequence, stream: "articles.indexed", consumer: "indexer")
  }
}
```

Committing the offset in the *same* transaction as the work it covers is what
makes the consumer correct. If the process dies mid-batch, both the work and the
offset roll back, and the next run reads the same records again. That gives
at-least-once delivery, so the work itself should be idempotent — keying derived
nodes by `{stream, sequence}` is a reliable way to get there.

``Database/streamOffset(_:consumer:)`` returns `nil` for a consumer that has
never committed one, which is distinct from a consumer parked at sequence 0.

## Waiting for records

``Database/readStream(_:after:limit:timeout:)`` returns immediately by default.
A non-zero `timeout` waits for a record to arrive:

```swift
let records = try database.readStream("articles.indexed", after: cursor, timeout: .seconds(5))
```

The wait is woken by a commit **from this process**. A consumer in a separate
process is not woken by another process's writes and should poll on an interval
instead.

## Trimming

Streams grow without bound until trimmed. ``Transaction/trimStream(_:through:)``
discards records through a sequence, permanently:

```swift
try database.write { try $0.trimStream("articles.indexed", through: safeSequence) }
```

Trimming ignores consumer offsets entirely — it will discard records a consumer
has not read. Compute the safe point as the minimum offset across every
consumer you intend to keep, and trim below that.

## See Also

- <doc:Transactions>
- <doc:SearchingAndRanking>
- ``Transaction/publish(_:to:kind:)``
- ``Database/readStream(_:after:limit:timeout:)``
