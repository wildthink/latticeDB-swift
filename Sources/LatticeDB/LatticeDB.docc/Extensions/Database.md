# ``LatticeDB/Database``

## Overview

A `Database` owns a native handle to one graph file and closes it when
released — hold one for the lifetime of your app rather than opening one per
query. Mutations and reads are scoped by ``read(_:)`` and ``write(_:)``; see
<doc:Transactions>.

Query and index methods live directly on the database because they manage their
own transactions internally.

## Topics

### Opening a Database

- ``init(path:configuration:)``
- ``DatabaseConfiguration``

### Transactions

- ``read(_:)``
- ``write(_:)``

### Declaring and Updating

- ``apply(schema:mergeStrategy:_:)``
- ``update(schema:mergeStrategy:_:)``

### Querying

- ``match(_:)-(Root.Type)``
- ``match(_:)-(Cypher)``
- ``match(_:as:)``
- ``matchFirst(_:)``
- ``matchFirst(_:as:)``
- ``matchScalar(_:as:)``
- ``matchCount(_:)``
- ``matchJSON(_:parameters:)``
- ``nodeTypes()``
- ``nodeSummaryJSON(_:)``

### Indexes

- ``createNodeIndex(label:property:)``
- ``dropNodeIndex(label:property:)``
- ``createEdgeIndex(type:property:)``
- ``dropEdgeIndex(type:property:)``

### Full-Text Search

- ``createFullTextIndex(label:property:)``
- ``dropFullTextIndex(label:property:)``
- ``fullTextIndexExists(label:property:)``
- ``createFullTextIndex(edgeType:property:)``
- ``dropFullTextIndex(edgeType:property:)``
- ``fullTextIndexExists(edgeType:property:)``
- ``fullTextSearch(_:label:property:limit:fuzzy:)``

### Vector Search

- ``vectorSearch(_:limit:efSearch:)``

### Durable Streams

- ``readStream(_:after:limit:timeout:)``
- ``lastSequence(ofStream:)``
- ``streamOffset(_:consumer:)``
