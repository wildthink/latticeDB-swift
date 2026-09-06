// Repro: a closure literal that follows a swift-testing macro invocation inside
// an enclosing closure silently gets the MACRO's closure body.
//
// Swift 6.3.3 (swiftlang-6.3.3.1.3), arm64-apple-macosx26.0, debug build.
// Run with: swift test
//
// Both expectations below SHOULD pass. `corrupted` fails: it returns ["p"],
// which is what the closure inside #require returns, not what its own body says.
//
// Symbol evidence (nm on the object file): `corrupted` has FOUR (Box) -> Bool
// closures in source but only THREE mangled symbols are emitted (…XEfU0_,
// …XEfU1_, …XEfU2_ — note the numbering starts at U0_, not U_). The macro's
// closure and the first following closure collide on one mangled name, so only
// one body is emitted and both call sites bind to it.
//
// Requires ALL of:
//   1. an enclosing closure (any closure-taking function; need not be generic
//      or throwing),
//   2. a swift-testing macro (#require or #expect) whose argument contains a
//      closure literal,
//   3. a closure literal AFTER it in the same scope.
// Only the FIRST closure after the macro is affected. Inserting any closure
// (or a `print` with string interpolation) before the macro shifts the
// numbering and masks it.

import Testing

private struct P {}
private struct Q {}
private enum Rec { case q(Q); case p(P) }
private struct Box { let record: Rec }
private func n(_ r: Rec) -> String { switch r { case .p: return "p"; case .q: return "q" } }
private func boxes() -> [Box] { [Box(record: .p(P())), Box(record: .q(Q()))] }
private func wrap(_ body: () throws -> Void) rethrows { try body() }

@Test func corrupted() throws {
  try wrap {
    let items = boxes()
    _ = try #require(items.first { if case .p = $0.record { return true } else { return false } })
    let kept = items.filter { if case .p = $0.record { return false } else { return true } }
    #expect(kept.map { n($0.record) } == ["q"])  // FAILS: returns ["p"]
  }
}

@Test func control() throws {
  try wrap {
    let items = boxes()
    let kept = items.filter { if case .p = $0.record { return false } else { return true } }
    #expect(kept.map { n($0.record) } == ["q"])  // passes
  }
}
