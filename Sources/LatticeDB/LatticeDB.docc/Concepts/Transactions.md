# Transactions

How reads and writes are scoped, committed, and rolled back.

## Overview

Every operation on the graph happens inside a ``Transaction``, and you never
create one directly. ``Database/read(_:)`` and ``Database/write(_:)`` hand a
transaction to a closure and own its lifetime:

```swift
let ada = try database.write { transaction in
  let node = try transaction.createNode(label: "Person")
  try transaction.setProperty("name", onNode: node, to: .string("Ada"))
  return node
}
```

The transaction **commits when the closure returns** and **rolls back when the
closure throws**. The closure's return value is passed back out, so pull the
identifiers or decoded results you need out of the closure — not the
transaction itself.

Both methods are `rethrows`-style generics over the closure's result, so
returning a tuple, an array, or nothing at all all work.

### Read versus write

``Database/read(_:)`` opens a read-only transaction; ``Database/write(_:)``
opens a read-write one. Use `read` where you can — it states intent, and the
engine can serve concurrent readers.

A database opened with ``DatabaseConfiguration/readOnly`` set to `true` rejects
writes at the handle level, which is the safer choice for a process that only
reports on data written elsewhere.

### Do not let the transaction escape

The one real footgun: a ``Transaction`` is only valid inside its closure. Once
the closure returns, the transaction is closed and every method on it throws
``LatticeError/transactionClosed``.

```swift
// Wrong — `escaped` is closed by the time it is used.
var escaped: Transaction?
try database.write { escaped = $0 }
try escaped?.createNode(label: "Person")  // throws .transactionClosed
```

Calling ``Transaction/commit()`` or ``Transaction/rollback()`` yourself closes
the transaction early, and the enclosing `read`/`write` will then throw when it
attempts its own commit. Reach for them only when you are managing a
transaction's fate deliberately inside the closure.

### Errors

Failures from the native engine surface as ``LatticeError/native(_:)`` carrying
the engine's status code. Because a throw rolls the transaction back, a partial
write is never left behind: either every mutation in the closure lands, or none
does.

```swift
do {
  try database.write { transaction in
    let node = try transaction.createNode(label: "Person")
    try transaction.setProperty("name", onNode: node, to: .string("Ada"))
    throw CancellationError()  // nothing above is persisted
  }
} catch { }
```

### Closing the database

``Database`` closes its native handle when the object is released. Hold it for
as long as your app needs the graph — opening one per query is wasteful, and a
`Database` is a natural fit for a long-lived dependency or actor.

## See Also

- <doc:GraphBasics>
- ``Database``
- ``Transaction``
