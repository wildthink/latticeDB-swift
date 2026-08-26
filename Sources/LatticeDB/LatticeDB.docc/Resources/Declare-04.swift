// Applying writes every declaration in one transaction, or none of them.
let result = try database.write { try plan.apply(in: $0) }

// The result maps each declaration back to the identifier it produced.
print(result.edges.count)  // 1

// `database.apply` wraps the same thing in its own write transaction.
try database.apply {
  for name in ["Bo Lin", "Chandra Rao"] {
    Node(.person) { Person.name .= name }
  }
}
