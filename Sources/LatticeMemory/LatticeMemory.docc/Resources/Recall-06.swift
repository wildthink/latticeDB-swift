let result = try store.retrieve(
  RetrievalRequest(query: "package manager", scope: acme, budget: .characters(2_000))
)

print(result.trace.candidates)
print(result.trace.dropped)
// [outOfScope: 3, overBudget: 1]
print(result.wasTruncated)
