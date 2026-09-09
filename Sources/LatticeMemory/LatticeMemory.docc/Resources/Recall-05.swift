let result = try store.retrieve(
  RetrievalRequest(
    query: "package manager",
    scope: acme,
    budget: .characters(2_000)
  )
)

print(result.rendered)

for item in result.items {
  print(item.score, item.explanation.lanes, item.text)
}
