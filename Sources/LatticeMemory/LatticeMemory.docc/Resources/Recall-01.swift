let current = try store.currentAssertions(in: acme)

for assertion in current {
  print(assertion.slot, assertion.value)
}
// package.manager string("pnpm")
