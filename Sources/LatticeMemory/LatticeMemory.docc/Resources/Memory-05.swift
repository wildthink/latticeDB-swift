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

let store = try MemoryStore(
  path: "memory.db",
  schema: schema,
  extractors: [
    PatternExtractor([
      .init(
        slot: "package.manager",
        pattern: #/(?:use|using|switched to)\s+(npm|pnpm|yarn)\b/#.ignoresCase()
      )
    ])
  ]
)
let acme: Scope = ["project": "acme"]

let ingested = try store.record(
  EvidenceDraft(kind: "commit", text: "Switched the build to pnpm.", scope: acme)
)
print(ingested.asserted.count)
// 1
