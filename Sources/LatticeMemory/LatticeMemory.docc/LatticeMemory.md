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

Three rules do most of the work:

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
  scoped, ranked set of records and a ``RetrievalTrace`` accounting for every
  candidate it discarded.

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

## Topics

### Essentials

- <doc:EvidenceAndAssertions>
- <doc:Retrieval>
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

### Retrieval

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

### Explaining a Result

- ``RetrievalTrace``
- ``DropReason``

### Embedding

- ``TextEmbedder``
- ``HashEmbedder``
- ``RemoteEmbedder``

### Errors and Refusals

- ``MemoryError``
- ``Rejection``
- ``RejectionReason``
