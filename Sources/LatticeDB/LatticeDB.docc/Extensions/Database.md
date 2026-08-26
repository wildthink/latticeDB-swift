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

### Querying

- ``matchJSON(_:parameters:)``
- ``nodeTypes()``
- ``nodeSummaryJSON(_:)``

### Indexes

- ``createNodeIndex(label:property:)``
- ``dropNodeIndex(label:property:)``
- ``createEdgeIndex(type:property:)``
- ``dropEdgeIndex(type:property:)``
