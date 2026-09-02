# Consolidation and Pinned Notes

Folding many records into one conclusion, and text that is always included.

## Overview

Two things belong in a store that a per-record extractor cannot produce.

A **consolidation** is a conclusion drawn from a body of records rather than
from any one of them: a digest of a week, a value corroborated by three sources,
a count. It is an ordinary ``Assertion`` that cites every record it came from.

A **pinned note** is authored rather than derived, and retrieval always includes
it within its scope. It is the escape hatch from ranking.

## Assertions with several citations

``MemoryStore/assert(_:from:)-(AssertionProposal,[RecordID])`` writes one
assertion supported by many records. Every citation gets its own provenance edge,
which is what makes the rest work: ``MemoryStore/forget(_:)`` already weakens an
assertion that loses some support and retracts one that loses all of it, with no
special case for summaries.

Two validation rules shift when there is more than one source:

- A **quote** need appear in only one of them. That is where it was read from.
- The **scope** must contain all of them, so the assertion is written to the
  narrowest scope covering every source — every dimension any of them declares.

The scope rule is worth dwelling on, because the intuitive answer is backwards.
A conclusion drawn from a record scoped `["project": "a", "user": "sam"]` and one
scoped `["project": "a"]` is written to `["project": "a", "user": "sam"]`, not to
what they have in common. Merging must narrow: a conclusion resting partly on
sam's record must not answer a query that never named sam. Taking only the shared
dimensions would widen it, and widening is how data leaks.

When two sources disagree about a dimension there is no scope covering both, and
the proposal is refused with
``RejectionReason/scopeEscapesEvidence(proposed:evidence:)``.

## Consolidating

A ``Consolidator`` reads many records and proposes conclusions. It is exactly as
trusted as an ``Extractor`` — which is to say not at all: every proposal goes
through the same schema validation, and a consolidator that throws is reported as
a rejection rather than failing the call.

```swift
try store.consolidate(
  .matching(kinds: ["log"], occurredIn: lastWeek),
  using: DigestConsolidator(slot: "week.digest"))
```

Selection uses the same rules as ``ForgetRequest`` — the same exact-scope
matching, the same skipping of tombstones — so what a forget preview shows you is
what a consolidation would have read. Selecting nothing writes nothing and is not
an error; a scheduled consolidation with no new records should be quiet.

Consolidating a single-valued slot twice supersedes rather than duplicating, so
re-running one as records accumulate leaves a history of digests rather than a
pile of them.

``DigestConsolidator`` is the deterministic default. It **summarizes nothing** —
it concatenates oldest-first and truncates. That is the point: it needs no model,
produces the same digest for the same records forever, and gives a real
summarizer a baseline to beat. Do not present its output as a summary.

## Pinned notes

Everything else in the store earns a place in a result by ranking. A
``PinnedNote`` does not — it is there because someone decided it should always be
there. A standing instruction, a piece of nameplate data, a caveat that has to
accompany every report: things a ranking function has no business deciding about.

```swift
try store.pin("Readings are uncalibrated below 5°C.", title: "caveat",
              scope: ["device": "sensor-4"])

try store.notes(in: ["device": "sensor-4"])
```

Pinning the same title in the same scope **edits in place**, keeping the note's
identifier, so a reference to a note survives a rewrite. Different scopes are
different notes, even under the same title — pinning broadly must not overwrite a
narrower note that happens to be visible from there.

Reading follows the usual visibility rule: a note scoped more narrowly than the
query stays hidden.

### In retrieval

Notes come back under ``RecordKinds/notes``, which ``RecordKinds/all`` includes.
They are **not ranked**. They lead the result and so get first claim on the
``Budget`` — a note that only sometimes survives is not pinned to anything. They
appear in a `Notes` section ahead of everything else.

Ask for `[.evidence]` or `[.assertions]` alone to leave them out.

### Notes and forgetting

``MemoryStore/forget(_:)`` does not touch notes. They cite no evidence, so there
is nothing linking one to a record that was forgotten — which means a note
repeating something you have just forgotten keeps repeating it. Editing or
unpinning it is a decision for whoever wrote it, and the library will not guess.

``MemoryStore/unpin(_:)`` deletes outright rather than tombstoning. Nothing cites
a note, so nothing needs to know it existed.

## See Also

- <doc:EvidenceAndAssertions>
- <doc:Retrieval>
- <doc:Forgetting>
