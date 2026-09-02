# Retrieval

Getting a bounded, scoped, explainable set of records back out.

## Overview

``MemoryStore/retrieve(_:)`` answers a question with the records that best serve
it, within a ceiling you set, and tells you what it left out. Ranking is
heuristic and always will be; the filtering around it is not. Everything after
candidate generation is deterministic, and every discarded candidate is counted.

```swift
let result = try store.retrieve(
  RetrievalRequest(
    query: "which package manager",
    scope: ["project": "acme"],
    budget: .characters(2_000)))

for item in result.items { print(item.text) }
```

## The pipeline

1. **Generate candidates** in the requested ``SearchMode``.
2. **Drop anything outside the scope.** Checked here as everywhere else.
3. **Apply time.** Assertions must hold at ``RetrievalRequest/validAt``, or be
   current when it is `nil`; evidence must fall inside
   ``RetrievalRequest/occurredIn``.
4. **Apply the request's filters** — kinds, slots, categories, evidence kinds.
5. **Suppress cited evidence**, unless asked not to.
6. **Fill the budget** in rank order; count the rest.

Order matters. Ranking runs first and filtering second, so a narrow scope needs a
wider ``RetrievalRequest/candidateLimit`` to fill a budget — the candidates
discarded in step 2 were already spent.

## Modes

``SearchMode/lexical`` is BM25 over the full-text indexes the store declares on
both labels. It is exact about words. Because the index is per-label, this is two
searches whose scores come from different indexes and are not comparable, so the
two lists are fused by rank rather than merged by score.

``SearchMode/vector`` embeds the query and searches nearest neighbors. It needs a
``MemoryStore/embedder``; without one it finds nothing rather than falling back,
so an explicitly requested mode never quietly becomes a different one.

``SearchMode/hybrid`` runs both and fuses them by reciprocal rank: each record
scores `1 / (60 + position)` in every ranking it appears in, summed. A record
both rankings like outranks one that either alone puts first, and no comparison
is ever made between a BM25 score and a distance.

``SearchMode/recency`` ignores the query and returns newest first.
``SearchMode/automatic`` — the default — picks hybrid when there is a query and
an embedder, lexical when there is a query but no embedder, and recency when
there is no query.

## Embedding

A store with a ``TextEmbedder`` writes a vector beside every record as it is
stored. ``HashEmbedder`` is deterministic and offline, which makes it right for
tests and reproducible fixtures and wrong as a semantic index — it encodes term
overlap, not meaning. ``RemoteEmbedder`` wraps an HTTP service.

Embedding happens *before* the write transaction opens, because a remote
embedder blocks on the network and a transaction holds its lock for as long as it
is open. An embedder that throws fails the whole ingest rather than storing a
record without a vector: a store where some records are searchable by vector and
others silently are not would rank the gap as though it meant something.

Adding an embedder to a store that already has records does not embed them. Only
what is written afterwards carries a vector.

## Suppressing cited evidence

When an assertion is returned, the evidence it cites usually repeats what the
assertion already says, at greater length. By default that evidence is dropped
and counted as ``DropReason/citedByAssertion``.

Turn ``RetrievalRequest/suppressesCitedEvidence`` off when the raw wording is the
point — showing a quote, diffing an original, auditing a conclusion. Evidence
nothing cites is never suppressed.

## Budgets

A ``Budget`` is a ceiling plus a definition of cost. ``Budget/characters(_:)``
counts characters, ``Budget/items(_:)`` counts records, and
``Budget/custom(_:measure:)`` counts whatever you count — tokens, bytes, rendered
height.

```swift
let budget = Budget.custom(4_000) { tokenizer.count($0) }
```

Retrieval fills the budget in rank order. An item that does not fit is skipped
rather than ending the loop, so a single outsized record does not truncate
everything behind it.

## Reading the trace

Retrieval that returns less than you expected is otherwise hard to diagnose: a
scope typo and an empty store look identical from the outside. They do not look
identical in ``RetrievalResult/trace``.

```swift
result.trace.candidates            // what ranking produced, before filtering
result.trace.dropped[.outOfScope]  // how many the scope excluded
result.trace.cost                  // what the returned items cost
result.wasTruncated                // whether the budget cut it short
```

Candidates always balance: returned items plus every drop count equals
``RetrievalTrace/candidates``. Zero candidates with a query means the query
matched nothing; many candidates and no items means your filters ate them, and
the counts say which one.

## Assembling output

``RetrievalResult/items`` is the flat ranking. ``RetrievalResult/sections``
groups it — assertions under their ``SlotRule/category``, then evidence — which
is usually the shape you want when writing a document.

``RetrievalResult/rendered`` joins the sections into plain text as a convenience.
It is deliberately plain; when the layout matters, walk the sections yourself.

## See Also

- <doc:EvidenceAndAssertions>
- ``MemoryStore/retrieve(_:)``
