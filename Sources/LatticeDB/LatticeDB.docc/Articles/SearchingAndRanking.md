# Searching and Ranking

Finding nodes by what their text says, or by what a vector says it means.

## Overview

Property indexes answer *which node has exactly this value*. Search answers the
looser question — which nodes are **about** something — and returns them ranked.
LatticeDB offers two rankings, and they are good at different things:

- **Full-text search** scores by term overlap (BM25). It is exact about words: a
  query for `kiln` finds documents containing `kiln`, and nothing else.
- **Vector search** scores by distance between embeddings. It finds neighbors
  that share no words at all, and it will happily return something plausible
  when the right answer is absent.

Neither subsumes the other, so many systems run both and fuse the results.

## Full-text search

Text is searchable only through a **declared index** over one label and one
property. Declaring the index is a database-level operation, not a transaction
one, and it fails while a write transaction is open.

```swift
try database.createFullTextIndex(label: "Article", property: "body")

try database.write { transaction in
  let article = try transaction.createNode(label: "Article")
  try transaction.setProperty("body", onNode: article, to: .string("firing a kiln"))
}

let matches = try database.fullTextSearch("kiln", label: "Article", property: "body")
```

Each ``TextMatch`` carries the node and its BM25 score, ordered best first.

Searching a label and property with no declared index **fails** rather than
returning an empty result. That is deliberate: no rows is indistinguishable from
a query that genuinely found nothing, so a mistyped property name would look
like a legitimate miss. Check with
``Database/fullTextIndexExists(label:property:)`` when a caller may not have
declared one.

Relationship text works the same way, through
``Database/createFullTextIndex(edgeType:property:)``.

### Typo tolerance

Pass a ``FuzzyMatching`` value to expand each query term to its near neighbors:

```swift
try database.fullTextSearch("kliln", label: "Article", property: "body", fuzzy: .default)
```

The default tolerates an edit distance of 2 on terms of at least 4 characters;
override either through ``FuzzyMatching/init(maximumEditDistance:minimumTermLength:)``.
Short terms are excluded because almost everything is within two edits of them.

One asymmetry to know: text written by the current transaction and not yet
committed matches by exact term only. A typo will not find a document that same
transaction has just written.

### Searching uncommitted writes

``Database/fullTextSearch(_:label:property:limit:fuzzy:)`` searches committed
state. Inside a transaction, ``Transaction/fullTextSearch(_:label:property:limit:fuzzy:)``
also sees that transaction's own writes — useful when you ingest and rank in one
unit of work.

## Vector search

Vector storage is off by default because its index costs space whether or not
you write a vector. Turn it on at open time, and give the width you intend to
store:

```swift
let database = try Database(
  path: path,
  configuration: DatabaseConfiguration(vectorDimensions: 768)
)
```

The width is recorded in the file, so every later open must agree with it.

Store a vector on a node, then search for nearest neighbors:

```swift
try database.write { transaction in
  try transaction.setVector(embedding, forKey: "embedding", onNode: article)
}

let neighbors = try database.vectorSearch(queryEmbedding, limit: 10)
```

``VectorMatch`` reports a **distance**, so lower is better — the reverse of
``TextMatch/score``. Search is approximate: it walks an HNSW graph rather than
comparing every stored vector, and `efSearch` sets how widely it walks. Raising
it improves recall at the cost of latency; `0` takes the engine default.

## Embeddings

Any vector works, from any source, so long as its width matches the database.
Two are built in:

``Embedding/hash(_:dimensions:)`` needs no network and is deterministic — the
same text always yields the same vector. That makes it the right choice for
tests and reproducible fixtures, but it encodes term overlap rather than
meaning, so it retrieves badly on paraphrases. Do not ship it as a semantic
index and expect semantic results.

``EmbeddingClient`` calls an HTTP service in the OpenAI or Ollama request shape:

```swift
let client = try EmbeddingClient(
  EmbeddingConfiguration(
    endpoint: "https://api.example.com/v1/embeddings",
    model: "text-embedding-3-small",
    apiKey: ProcessInfo.processInfo.environment["EMBEDDING_API_KEY"]
  )
)
let embedding = try client.embed("firing a kiln")
```

``EmbeddingClient/embed(_:)`` blocks on the network. Never call it inside
``Database/write(_:)``: the transaction would hold its lock for the whole
request. Embed first, then open the transaction to store the result.

## Fusing both rankings

BM25 scores and vector distances are not comparable numbers, so they cannot be
added. Reciprocal-rank fusion sidesteps that by scoring **positions** instead of
values:

```swift
func fuse(_ rankings: [[NodeID]], k: Double = 60) -> [NodeID] {
  var scores: [NodeID: Double] = [:]
  for ranking in rankings {
    for (index, node) in ranking.enumerated() {
      scores[node, default: 0] += 1 / (k + Double(index + 1))
    }
  }
  return scores.sorted { $0.value > $1.value }.map(\.key)
}

let lexical = try database.fullTextSearch(query, label: "Article", property: "body", limit: 50)
let semantic = try database.vectorSearch(try client.embed(query), limit: 50)
let ranked = fuse([lexical.map(\.node), semantic.map(\.node)])
```

A node that both rankings place highly rises above one that either ranks first
alone, which is usually the behavior you want. The constant `k` damps the top of
each list; 60 is the conventional starting point.

Because search returns node identifiers, the result composes with everything
else: traverse from a hit with ``Transaction/neighbors(of:outgoing:type:)``,
filter it by valid time as in <doc:TemporalGraphs>, or use the hits to anchor a
Cypher pattern.

## See Also

- <doc:IndexingAndPerformance>
- <doc:DurableStreams>
- ``Database/fullTextSearch(_:label:property:limit:fuzzy:)``
- ``Database/vectorSearch(_:limit:efSearch:)``
