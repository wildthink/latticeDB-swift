# Forgetting

Removing a record and everything that was concluded from it.

## Overview

Deleting a row is easy. Forgetting is harder, because a store that keeps
provenance has, by design, copied pieces of the record elsewhere: an assertion
derived from it, a quote lifted verbatim out of it, an embedding computed from
it. Discarding the original while those survive does not forget anything.

``MemoryStore/forget(_:)`` selects evidence, computes what depends on it, and
removes both — in one transaction, with a report of everything it touched.

```swift
let report = try store.forget(.identifiers([record.id]))
report.retractedAssertions   // lost all support
report.weakenedAssertions    // lost some, survived on the rest
```

## Preview first

Forgetting propagates, so a request naming three records can retract a dozen
assertions. ``MemoryStore/forgetPreview(_:)`` computes the identical closure and
writes nothing:

```swift
let preview = try store.forgetPreview(.matching(scope: ["user": "sam"]))
guard preview.retractedAssertions.count < 100 else { throw TooMuch() }
try store.forget(.matching(scope: ["user": "sam"]))
```

Both return a ``ForgetReport``; ``ForgetReport/wasApplied`` says which you have.

## Selecting

A request selects by identifier, or by any combination of full-text query,
scope, evidence kind, and time window.

```swift
.identifiers([a, b])
.matching(query: "passphrase")
.matching(scope: ["user": "sam"], occurredIn: lastYear)
```

Two guards apply. A request that names **nothing** is refused with
``ForgetError/unconstrained`` rather than matching the whole store. And
``ForgetRequest/limit`` — 1,000 by default — caps how much one call may remove,
turning an over-broad filter into a truncated report instead of a cleared store.
``ForgetReport/wasTruncated`` says when it was reached.

Scope selection matches the stored scope **exactly**, not by visibility. A
request scoped `["project": "acme"]` does not reach a record scoped
`["project": "acme", "user": "sam"]`, even though a *read* in the broader scope
would see it. Reading and destroying should not have the same reach.

## Tombstone or erase

``ForgetMode/tombstone``, the default, keeps the record's identifier, kind, and
timestamps and discards its text, metadata, and embedding. A reference to it
resolves to "this was forgotten" rather than to nothing, which is what lets an
audit show that a deletion happened and when. ``Evidence/isForgotten`` marks it.

``ForgetMode/erase`` deletes the node outright. Afterwards
``MemoryStore/evidence(_:)`` returns `nil` for the identifier, exactly as it
would for one never stored. Use it when a tombstone is itself too much — an
erasure request you have to be able to certify.

Tombstones stay visible to ``MemoryStore/evidence(supporting:)``, because a
redacted citation and a citation that never existed are different facts and a
reader needs to tell them apart. They are never returned by
``MemoryStore/retrieve(_:)``.

## What propagation does

**An assertion whose citations are all forgotten** is retracted. In tombstone
mode its value, text, and quote are redacted as well. That last part is the
whole point: a quote is a verbatim copy of the forgotten text, and the derived
text usually paraphrases it closely. Retracting the assertion while leaving its
quote readable would forget nothing at all.

**An assertion with surviving citations** stands, minus the forgotten ones, and
is reported as a ``WeakenedAssertion``. Its quote is dropped only when the text
it quoted appears in none of the remaining evidence — if another surviving record
contains the same words, the citation still checks out and is kept.

**Supersession is never undone.** That a value was replaced remains true whatever
becomes of the evidence for its replacement. Forgetting the newer record retracts
the newer assertion; the older one stays superseded rather than springing back to
current. Resurrecting it would assert something no evidence supports.

**Embeddings are overwritten with zeroes.** The native API has no vector
removal, and a live embedding of forgotten text still answers a nearest-neighbor
search for that text.

## Re-forgetting

Forgetting a tombstone again selects nothing and reports nothing — the record has
no content left to remove, and counting its dependents twice would misreport the
closure. Forgetting an unknown identifier likewise selects nothing rather than
failing.

## See Also

- <doc:EvidenceAndAssertions>
- <doc:Retrieval>
- ``MemoryStore/forget(_:)``
- ``MemoryStore/forgetPreview(_:)``
