# ``LatticeMemory``

Records that keep their evidence, their scope, and their history.

## Overview

`LatticeMemory` stores two kinds of thing on top of `Database`:
**evidence**, which is raw and never rewritten, and **assertions**, which are
derived from evidence and carry a link back to it.

The point of the split is that a stored conclusion is never orphaned. Every
assertion names the evidence that justifies it and, when a rule asks for one,
quotes the exact span of text it was read from — a quote the store checks
appears verbatim before it writes anything. So "why does the system believe
this?" is a query, not an investigation.

A handful of rules do most of the work:

- **Values are superseded, not overwritten.** Writing a new value for a
  single-valued slot closes the old one's valid interval and leaves it readable.
  ``MemoryStore/assertions(validAt:in:slot:category:)`` answers what was held to
  be true at any past moment.
- **Scope is checked on every read.** A record is visible only when every
  dimension it declares appears in the querying ``Scope`` with the same value, so
  one project's data cannot answer another project's question.
- **Extractors propose; the store decides.** An ``Extractor`` can suggest
  anything. The ``MemorySchema`` decides what is actually written.
- **Retrieval explains itself.** ``MemoryStore/retrieve(_:)`` returns a bounded,
  scoped, ranked set of records, a ``RetrievalTrace`` accounting for every
  candidate it discarded, and a ``RankExplanation`` on each item naming the
  lanes that placed it.
- **Records can be tagged with what they are about.** A ``Facet`` is a typed
  reference — a person, a project — that ranks exactly, so a record about
  someone is found whether or not the text spells their name.
- **Two spellings can be one term.** An ``Alias`` maps a term to a canonical
  form, resolved on the way in so a slot holds one spelling of a value, and on
  the way out so a query naming an alias finds what it stands for.
- **Some things are not ranked.** A ``PinnedNote`` is always included within its
  scope, and a ``Consolidator`` folds many records into one conclusion that cites
  all of them.
- **Forgetting propagates.** ``MemoryStore/forget(_:)`` removes a record and
  every conclusion that rested on it, including the quotes copied out of it.
- **Slow work happens later, durably.** A change can publish an event that
  ``MemoryStore/materialize(stream:worker:limit:)`` turns into leased ``Job``
  records, so work triggered by a write outlives the process that triggered it.

Nothing here is specific to any one domain. A slot is a name you choose; a scope
dimension is a name you choose; ``PatternExtractor`` is regular expressions over
text. The same store suits a configuration history, a document-extraction
pipeline, a device's derived state, or an agent's long-term memory.

```swift
let store = try MemoryStore(
  path: "memory.db",
  schema: [
    "package.manager": SlotRule(allowedValues: ["npm", "pnpm", "yarn"])
  ],
  extractors: [
    PatternExtractor([.init(slot: "package.manager", pattern: #/using (npm|pnpm|yarn)/#)])
  ]
)

try store.record(EvidenceDraft(text: "We are using pnpm.", scope: ["project": "acme"]))
let current = try store.currentAssertions(in: ["project": "acme"])
```

Everything here is stored as nodes and edges in an ordinary graph file. The
`LatticeDB` module documents that layer: `Database`, transactions, Cypher, and
the full-text and vector indexes this store ranks with. Reach for it directly
whenever you want to query the graph beneath a memory, and start with its
*Getting Started* article if you have not opened a database before.

New here? Follow <doc:/tutorials/Memory>.

## Topics

### Essentials

- <doc:/tutorials/Memory>
- <doc:EvidenceAndAssertions>
- <doc:Retrieval>
- <doc:Consolidation>
- <doc:Forgetting>
- <doc:DeferredWork>
- ``MemoryStore``
- ``Scope``
- ``RecordID``

### Records

- ``Evidence``
- ``EvidenceDraft``
- ``Assertion``
- ``AssertionState``

### Declaring What May Be Stored

- ``MemorySchema``
- ``Slot``
- ``SlotRule``
- ``Cardinality``

### Extraction

- ``Extractor``
- ``PatternExtractor``
- ``AssertionProposal``
- ``IngestResult``

### Consolidating and Pinning

- <doc:Consolidation>
- ``MemoryStore/assert(_:from:)-(AssertionProposal,[RecordID])``
- ``MemoryStore/consolidate(_:using:)``
- ``Consolidator``
- ``DigestConsolidator``
- ``ConsolidationRequest``
- ``ConsolidationResult``
- ``PinnedNote``
- ``MemoryStore/pin(_:title:scope:)``
- ``MemoryStore/unpin(_:)``
- ``MemoryStore/notes(in:)``
- ``MemoryStore/note(title:scope:)``

### Retrieving Records

- <doc:Retrieval>
- ``MemoryStore/retrieve(_:)``
- ``RetrievalRequest``
- ``RetrievalResult``
- ``RetrievedItem``
- ``RetrievedRecord``
- ``RetrievalSection``
- ``SearchMode``
- ``RecordKinds``
- ``Budget``

### Forgetting Records

- <doc:Forgetting>
- ``MemoryStore/forget(_:)``
- ``MemoryStore/forgetPreview(_:)``
- ``ForgetRequest``
- ``ForgetMode``
- ``ForgetReport``
- ``WeakenedAssertion``
- ``ForgetError``

### Deferred Work

- <doc:DeferredWork>
- ``MemoryStore/eventStream``
- ``MemoryStore/EventKind``
- ``MemoryStore/materialize(stream:worker:limit:)``
- ``MemoryStore/lease(worker:count:duration:)``
- ``MemoryStore/run(worker:count:lease:_:)``
- ``MemoryStore/complete(_:)``
- ``MemoryStore/fail(_:error:)``
- ``MemoryStore/retry(_:)``
- ``MemoryStore/jobs(worker:state:)``
- ``MemoryStore/job(_:)``
- ``MemoryStore/pruneJobs(worker:includingFailed:)``
- ``Job``
- ``JobState``
- ``JobRunReport``

### Facets

- ``Facet``
- ``FacetWeights``
- ``MemoryStore/facets(of:)``
- ``MemoryStore/records(mentioning:)``

### Aliases

- ``Alias``
- ``AliasNamespace``
- ``MemoryStore/alias(_:to:in:)``
- ``MemoryStore/unalias(_:in:)``
- ``MemoryStore/canonical(for:in:)``
- ``MemoryStore/aliases(in:)``

### Explaining a Result

- ``RetrievalTrace``
- ``DropReason``
- ``RankExplanation``
- ``RankingLane``
- ``LaneContribution``

### Embedding

- ``TextEmbedder``
- ``HashEmbedder``
- ``RemoteEmbedder``

### Errors and Refusals

- ``MemoryError``
- ``Rejection``
- ``RejectionReason``
- ``AliasError``
