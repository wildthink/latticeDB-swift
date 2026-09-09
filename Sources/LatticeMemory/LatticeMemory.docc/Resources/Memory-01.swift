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
