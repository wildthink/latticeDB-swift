# ``LatticeDB/Transaction``

## Overview

A transaction is valid only inside the ``Database/read(_:)`` or
``Database/write(_:)`` closure that receives it. It commits when the closure
returns and rolls back when the closure throws; using it afterward throws
``LatticeError/transactionClosed``. See <doc:Transactions>.

Most members come in two spellings: one taking strings, and one taking the
modeled ``NodeType``, ``EdgeType``, and ``PropertyKey`` values described in
<doc:DeclarativeGraphs>.

## Topics

### Nodes

- ``createNode(label:)``
- ``createNode(_:)``
- ``nodeExists(_:)``
- ``deleteNode(_:)``
- ``nodeIDs(label:)``
- ``nodeIDs(_:)``
- ``nodeIDs(of:)``
- ``nodeIDs(label:property:equals:limit:)``
- ``nodeIDs(_:where:equals:limit:)``
- ``allNodeIDs()``
- ``node(_:as:)``
- ``nodes(of:)``

### Labels

- ``addLabel(_:to:)-(String,_)``
- ``addLabel(_:to:)-(NodeType,_)``
- ``removeLabel(_:from:)-(String,_)``
- ``removeLabel(_:from:)-(NodeType,_)``
- ``labels(of:)``
- ``nodeTypes(of:)``

### Edges

- ``createEdge(from:to:type:)-(_,_,String)``
- ``createEdge(from:to:type:)-(_,_,EdgeType)``
- ``deleteEdge(from:to:type:)-(_,_,String)``
- ``deleteEdge(from:to:type:)-(_,_,EdgeType)``
- ``edges(for:outgoing:type:)``
- ``neighbors(of:outgoing:type:)``
- ``edgesJSON(for:outgoing:type:)``

### Properties

- ``setProperty(_:onNode:to:)-(_,_,Value)``
- ``setProperty(_:onNode:to:)-(_,_,V)``
- ``setProperty(_:onEdge:to:)-(_,_,Value)``
- ``setProperty(_:onEdge:to:)-(_,_,V)``
- ``setProperties(_:onNode:)``
- ``setProperties(_:onEdge:)``
- ``apply(_:onNode:)``
- ``apply(_:onEdge:)``
- ``property(_:ofNode:)``
- ``property(_:ofEdge:)``
- ``propertyValue(_:ofNode:)``
- ``propertyValue(_:ofEdge:)``
- ``removeProperty(_:fromEdge:)``
- ``nodePropertyJSON(_:of:)``

### Declaring and Querying

- ``apply(schema:mergeStrategy:_:)``
- ``match(_:)``
- ``match(_:as:)``
- ``matchJSON(_:parameters:)``

### Valid Time

- ``setTemporalValidity(_:onNode:fromKey:toKey:)``
- ``setTemporalValidity(_:onEdge:fromKey:toKey:)``

### Ending a Transaction

- ``commit()``
- ``rollback()``
