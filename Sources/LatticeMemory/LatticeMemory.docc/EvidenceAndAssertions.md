# Evidence and Assertions

What the store keeps, what it derives, and what it refuses.

## Overview

A store holds raw records and conclusions drawn from them, and keeps the link
between the two. Understanding four ideas — evidence, slots, scope, and valid
time — is enough to use the whole library.

## Evidence is the ground truth

``Evidence`` is whatever arrived: a message, a commit, a form submission, a
sensor reading, a paragraph of a document. It has a `kind` you choose, a `text`
the store indexes for search, arbitrary `metadata`, and two timestamps.

The two timestamps are worth separating. `recordedAt` is when the store learned
it; `occurredAt` is when the thing actually happened. Backfilling last month's
records sets `occurredAt` in the past, and everything derived from them lands in
the right place in history rather than in arrival order.

```swift
try store.record(
  EvidenceDraft(
    kind: "commit",
    text: "Switched the repo to pnpm.",
    scope: ["project": "acme"],
    occurredAt: commitDate,
    metadata: ["sha": .string(sha)]))
```

Evidence is never edited. That is what makes it usable as a citation.

## Assertions are derived, and say where they came from

An ``Assertion`` fills a ``Slot`` — a name like `package.manager` or
`sensor.calibration` — with a value, within a ``Scope``, over an interval of
time. It carries the ``RecordID`` of the evidence behind it and, usually, the
`quote` it was read from.

Slots are declared in a ``MemorySchema``, and the ``SlotRule`` for each says what
may fill it: the value's kind, an optional set of permitted values, whether a
quote is mandatory, and whether the slot holds one current value or many.

```swift
let schema: MemorySchema = [
  "package.manager": SlotRule(allowedValues: ["npm", "pnpm", "yarn"]),
  "project.test_command": SlotRule(requiresQuote: true),
  "document.topic": SlotRule(cardinality: .multiple),
]
```

``SlotRule/category`` groups slots however your domain divides them, and becomes
a read filter. There is no built-in taxonomy to work around.

## Extractors propose, the store decides

An ``Extractor`` reads evidence and returns ``AssertionProposal`` values. It has
no write access at all. The store checks each proposal and refuses it unless it

- names a slot the schema declares,
- carries a value of the declared kind, and one of the permitted values,
- carries a quote when the rule demands one — and any quote it carries appears
  **verbatim** in the evidence text,
- stays inside the evidence's scope, and
- reports a confidence between 0 and 1.

That division is the reason an unaudited extractor is safe to run. A heuristic
you wrote in five minutes, or a remote model that will occasionally hallucinate a
citation, can still only produce values the schema already permits, attributed to
text that actually exists.

Refusals are reported, not thrown. ``MemoryStore/record(_:)`` returns an
``IngestResult`` whose ``IngestResult/rejected`` array explains every proposal
that did not make it, so a bad proposal never costs you the evidence beside it —
and never leaves you wondering why an assertion is missing.

```swift
let result = try store.record(draft)
for rejection in result.rejected {
  logger.warning("refused \(rejection.proposal.slot): \(rejection.reason)")
}
```

``PatternExtractor`` is the deterministic default: regular expressions mapped to
slots, no network, no model, same output forever. Because it uses the matched
span as the quote, its citations are verbatim by construction.

## Scope keeps contexts apart

A ``Scope`` is a set of named dimensions — `["project": "acme", "user": "sam"]`.
You choose the names; nothing interprets them.

A record is visible to a query when **every dimension the record declares appears
in the query with the same value**. So a record scoped `["project": "acme"]`
answers a query scoped `["project": "acme", "user": "sam"]`, but a record scoped
to a particular user stays hidden from a query that did not name one. A query
that does not say which user cannot be answered with one user's data.

Supersession is stricter still: it matches the stored scope **exactly**. Setting
`package.manager` for one project never disturbs another project's value for the
same slot, even though both are visible from a broader query.

## Valid time makes history answerable

Writing a new value for a single-valued slot does not overwrite the old one. The
old assertion becomes ``AssertionState/superseded`` and its ``Assertion/validTo``
closes at the moment the new one became true. The interval is half-open —
`validFrom` inclusive, `validTo` exclusive — so no instant is ever covered twice.

```swift
try store.currentAssertions(in: scope)              // what holds now
try store.assertions(validAt: lastMarch, in: scope) // what held then
try store.history(of: "package.manager", in: scope) // every value, newest first
```

``MemoryStore/retract(_:)`` closes an assertion without replacing it, for a value
that stopped being true rather than changing. Nothing is deleted in either case:
a superseded value is still true of its interval, and that remains worth knowing.

## Provenance runs both ways

``MemoryStore/evidence(supporting:)`` goes from a conclusion to its sources.
``MemoryStore/assertions(derivedFrom:)`` goes the other way, and is the query
that says what would be affected if a record were withdrawn.

Both are ordinary graph edges — `EVIDENCED_BY` from an assertion to its evidence,
`SUPERSEDES` from a new assertion to the one it replaced — on the store's
``MemoryStore/database``. Nothing stops you traversing them yourself, or joining
them to nodes this library knows nothing about.
