try database.read { transaction in
  // Every Person node, without a query.
  let people = try transaction.nodeIDs(label: "Person")

  // One property, JSON-encoded.
  let name = try transaction.nodePropertyJSON("name", of: people[0])  // "\"Ada Chen\""

  // A node's outgoing edges, optionally filtered by type.
  let knows = try transaction.edgesJSON(for: people[0], outgoing: true, type: "KNOWS")
}

// Labels plus both edge directions, in one object.
let summary = try database.nodeSummaryJSON(1)
// {"id":1,"labels":["Person"],"outgoing":[...],"incoming":[...]}
