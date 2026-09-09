import Foundation
import LatticeDB
import LatticeMemory

let schema: MemorySchema = [
  "package.manager": SlotRule(
    kind: .string,
    category: "tooling",
    allowedValues: ["npm", "pnpm", "yarn"]
  )
]

let store = try MemoryStore(path: "memory.db", schema: schema)
let acme: Scope = ["project": "acme"]

let ingested = try store.record(
  EvidenceDraft(
    kind: "commit",
    text: "Switched the build to pnpm.",
    scope: acme
  )
)

try store.assert(
  AssertionProposal(
    slot: "package.manager",
    value: .string("pnpm"),
    text: "The project uses pnpm.",
    quote: "Switched the build to pnpm."
  ),
  from: ingested.evidence.id
)
