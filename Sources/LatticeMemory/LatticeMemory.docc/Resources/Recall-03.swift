let later = try store.record(
  EvidenceDraft(kind: "commit", text: "Moved back to npm.", scope: acme)
)

try store.assert(
  AssertionProposal(slot: "package.manager", value: .string("npm")),
  from: later.evidence.id
)

let history = try store.history(of: "package.manager", in: acme)
print(history.map(\.value))
// [string("npm"), string("pnpm")] — newest first
