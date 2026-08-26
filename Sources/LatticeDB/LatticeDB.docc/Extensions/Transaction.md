# ``LatticeDB/Transaction``

## Overview

A transaction is valid only inside the ``Database/read(_:)`` or
``Database/write(_:)`` closure that receives it. It commits when the closure
returns and rolls back when the closure throws; using it afterward throws
``LatticeError/transactionClosed``. See <doc:Transactions>.

## Topics

### Nodes

- ``createNode(label:)``
- ``nodeExists(_:)``
- ``deleteNode(_:)``
- ``nodeIDs(label:)``
- ``allNodeIDs()``

### Labels

- ``addLabel(_:to:)``
- ``removeLabel(_:from:)``
- ``labels(of:)``

### Edges

- ``createEdge(from:to:type:)``
- ``deleteEdge(from:to:type:)``
- ``edgesJSON(for:outgoing:type:)``

### Properties

- ``setProperty(_:onNode:to:)``
- ``setProperty(_:onEdge:to:)``
- ``setProperties(_:onNode:)``
- ``setProperties(_:onEdge:)``
- ``nodePropertyJSON(_:of:)``

### Valid Time

- ``setTemporalValidity(_:onNode:fromKey:toKey:)``
- ``setTemporalValidity(_:onEdge:fromKey:toKey:)``

### Ending a Transaction

- ``commit()``
- ``rollback()``
