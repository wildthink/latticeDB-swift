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

1. **Generate candidates** from every lane in play — the ``SearchMode``'s
   lanes, plus the facet lane when the request names facets — fused by rank.
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
there is neither a query nor facets.

## Facets

A ``Facet`` is a typed reference a record is tagged with: a kind and an
identifier, both yours to choose. Facets are what a record *concerns*, as opposed
to what it *says*, and matching them is exact — a record tagged
`Facet("person", "sam")` matches whether or not the text spells the name, and a
record that merely uses the word does not match unless it was tagged.

```swift
try store.record(
  EvidenceDraft(text: "Shipped the rollout.", facets: [Facet("person", "sam")]))

let result = try store.retrieve(
  RetrievalRequest(
    query: "rollout",
    facets: [Facet("person", "sam")],
    facetWeights: ["person": 4, "project": 1]))
```

Facets are tagged, never proposed. ``EvidenceDraft`` carries them and
``AssertionProposal`` does not: an assertion inherits the union of its evidence's
facets when it commits, so a conclusion is about whatever its sources were about.
An ``Extractor`` cannot invent what a record is about, which keeps the trust
boundary where the ``MemorySchema`` already put it.

**Facets rank; they do not filter.** A record tagged with none of the requested
facets still comes back when the query finds it — the tagged one simply leads.
Use ``MemoryStore/records(mentioning:)`` when you want only what is tagged; it
answers from the graph rather than from a ranking, so it is exact and unbudgeted.

``FacetWeights`` decides which kind counts for more. The weights order the lane
and nothing else: reciprocal rank fusion uses only that order, so they settle who
outranks whom without ever being compared against a BM25 score.

The lane runs alongside whichever mode is in force, so facets and query text
combine rather than compete, and facets with no query rank on their own instead
of falling back to recency. The one exception is an explicit
``SearchMode/recency``, which asks for the newest records and so ignores every
relevance signal, facets included.

Storage is one shared node per facet with an edge from each record carrying it,
so the cost of a facet lookup follows how many records carry it rather than how
many the store holds. Forgetting detaches a record's facets and prunes any facet
left tagging nothing: what a record was about is as revealing as what it said.

## Aliases

An ``Alias`` maps a term to a canonical form within an ``AliasNamespace``.
Retrieval consults the ``AliasNamespace/query`` namespace and appends the
canonical form of every alias the query mentions before searching, so a query
naming an alias finds what it stands for.

```swift
try store.alias("fra", to: "Frankfurt", in: .query)
try store.retrieve(RetrievalRequest(query: "fra", mode: .lexical))  // finds Frankfurt
```

Terms are appended rather than substituted, so the words actually typed still
rank and BM25 treats the result as the bag of words it is. Both the whole query
and each of its words are looked up, so a multi-word alias resolves as readily as
a single term, and a canonical term the query already contains is not repeated.

Aliases also apply on the way in, where they canonicalize assertion values rather
than queries — see ``MemoryStore/alias(_:to:in:)``.

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
result.trace.laneCoverage[.vector] // how many returned items that lane placed
result.wasTruncated                // whether the budget cut it short
```

Candidates always balance: returned items plus every drop count equals
``RetrievalTrace/candidates``. Zero candidates with a query means the query
matched nothing; many candidates and no items means your filters ate them, and
the counts say which one.

``RetrievalTrace/laneCoverage`` says what each lane contributed. A lane missing
from it placed nothing, which is worth knowing because the failure is otherwise
invisible: an embedder whose dimensions do not match the database returns no
matches rather than failing, so hybrid retrieval quietly running on one lane
looks exactly like hybrid retrieval working. Hybrid adds a warning when a lane
places nothing.

## Why one record outranked another

Each ``RetrievedItem`` carries a ``RankExplanation`` saying what produced its
score — pinned, ordered by recency, or fused from the lanes that placed it, with
each lane's position and contribution.

```swift
for item in result.items {
  switch item.explanation {
  case .pinned:                    print("always included")
  case .recency(let position):     print("newest, #\(position)")
  case .fused(let contributions):
    for c in contributions { print(c.lane, c.position, c.score) }
  }
}
```

It explains the fusion, not the relevance: it reports that the vector lane placed
a record third and the lexical lane did not place it at all, not which terms
matched. Per-term attribution would need BM25 internals the index does not
expose.

## Assembling output

``RetrievalResult/items`` is the flat ranking. ``RetrievalResult/sections``
groups it — assertions under their ``SlotRule/category``, then evidence — which
is usually the shape you want when writing a document.

``RetrievalResult/rendered`` joins the sections into plain text as a convenience.
It is deliberately plain; when the layout matters, walk the sections yourself.

## See Also

- <doc:EvidenceAndAssertions>
- ``MemoryStore/retrieve(_:)``
- ``Facet``
- ``Alias``
