# Deferred Work

Doing later, reliably, what should not happen during a write.

## Overview

Some work belongs after a write rather than inside it. Calling an embedding
service, notifying another system, re-consolidating a week's records — each is
slow, fallible, or both, and a write transaction holds its lock for as long as it
is open.

Deferring it to memory is not enough: an in-process queue loses its contents when
the process stops. `LatticeMemory` defers through the database itself. A change
publishes an event to a durable stream in the same transaction; a later pass
turns those events into ``Job`` records; a worker leases jobs, does the work, and
marks them done.

```swift
store.eventStream = "memory.events"
try store.record(EvidenceDraft(text: "…"))          // publishes an event

try store.materialize(stream: "memory.events", worker: "embedder")
try store.run(worker: "embedder", count: 10) { job in
  guard case .string(let id) = job.payload else { return }
  try backfillEmbedding(for: RecordID(id))
}
```

## Events

Publishing is off by default; set ``MemoryStore/eventStream`` to turn it on. A
store that defers nothing should not pay for a stream write on every record.

``MemoryStore/record(_:)`` publishes ``MemoryStore/EventKind/evidenceRecorded``
and ``MemoryStore/forget(_:)`` publishes
``MemoryStore/EventKind/evidenceForgotten``, each carrying the record's
identifier as its payload. Both publish **inside the transaction that made the
change**, so an event never survives a write that rolled back — a duplicate
identifier refused by ``MemoryError/duplicateIdentifier(_:)`` leaves no event
behind.

Nothing stops you publishing your own events to your own stream with
`Transaction.publish(_:to:kind:)` and materializing from that
instead. The job machinery does not care where a stream record came from.

## Materializing

``MemoryStore/materialize(stream:worker:limit:)`` reads a stream and creates one
pending job per record, for one worker.

It is idempotent twice over. Reading resumes from the offset that worker last
committed, and the new offset is written in the same transaction as the jobs it
covers — so a crash mid-pass rolls both back and the next call re-reads the same
records. That handles interruption but not two materializers running at once, so
each job also carries a unique `{stream, sequence, worker}` key and a duplicate is
skipped rather than written.

The upshot is that materializing on a timer is safe. Running it twice creates
nothing the first run already made.

Each **worker** gets its own job for the same stream record, so several
independent consumers can each act on one event without coordinating.

## Leasing

``MemoryStore/lease(worker:count:duration:)`` claims pending jobs and stamps each
with a deadline.

A lease is a deadline, not a lock. A job whose lease has expired becomes
available again, which is what stops a crashed worker from stranding work — and
is exactly why **a handler must tolerate running twice**. Delivery is
at-least-once. Key any derived record by something stable, and re-running becomes
a no-op rather than a duplicate.

Leasing increments ``Job/attempts``. A job that uses up
``MemoryStore/maximumJobAttempts`` without completing becomes
``JobState/failed`` and is not leased again;
``MemoryStore/retry(_:)`` puts it back with a clean count once you have fixed
whatever was breaking it.

## Running

``MemoryStore/run(worker:count:lease:_:)`` is the loop: lease, call the handler,
complete on return, fail on throw. One handler throwing does not stop the pass,
and the error text is kept on the job — ``MemoryStore/jobs(worker:state:)`` with
``JobState/failed`` is where to look when something is not happening.

``MemoryStore/complete(_:)`` and ``MemoryStore/fail(_:error:)`` are there for a
worker that manages its own loop.

Finished jobs accumulate and nothing depends on them.
``MemoryStore/pruneJobs(worker:includingFailed:)`` clears them out, keeping
failures by default because they are usually the reason you are looking.

## Jobs are not memory

A ``Job`` is operational. It is not evidence, nothing cites it, and it takes no
part in scope, valid time, retrieval, or forgetting. Forgetting a record does not
retract a job that mentions its identifier — a job whose payload names a record
that has since been erased should simply find nothing and complete.

## See Also

- <doc:EvidenceAndAssertions>
- <doc:Consolidation>
- ``MemoryStore/materialize(stream:worker:limit:)``
- ``MemoryStore/run(worker:count:lease:_:)``
