let current = try store.currentAssertions(in: acme)

for assertion in current {
  print(assertion.slot, assertion.value)
}
// package.manager string("pnpm")

let sources = try store.evidence(supporting: current[0].id)
print(sources.map(\.text))
// ["Switched the build to pnpm."]
