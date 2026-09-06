# A closure after a swift-testing macro can get the macro's closure body

**Status:** open, not yet filed upstream. Reproduced against Swift 6.3.3
(`swiftlang-6.3.3.1.3`, `arm64-apple-macosx26.0`), debug build.

**Affects:** test code only. `Sources/` is safe — see [Blast radius](#blast-radius).

## Summary

Inside an enclosing closure, a closure literal that *follows* a swift-testing
macro invocation silently executes **the macro's closure body instead of its
own**. It compiles without warning and the wrong predicate simply runs.

This was found while writing `Tests/LatticeMemoryTests/RetrievalTests.swift`.
The test read:

```swift
try withStore { store in
  let result = try store.retrieve(RetrievalRequest(mode: .recency))
  let note = try #require(
    result.items.first { if case .note = $0.record { return true } else { return false } })
  let ranked = result.items.filter { if case .note = $0.record { return false } else { return true } }
  ...
}
```

`result.items` was `[note, assertion]`. `ranked` came back as `[note]` — the
`filter` ran the `#require`'s closure, which returns `true` for a note, instead
of its own, which returns `false`.

## Reproduction

`SwiftClosureDiscriminatorRepro.swift` in this directory is a self-contained
drop-in: add it to any test target with swift-testing and run `swift test`.
`corrupted()` fails, `control()` passes.

All three ingredients are required:

1. an **enclosing closure** — need not be generic, need not throw;
2. a **swift-testing macro** (`#require` or `#expect`) whose argument contains a
   closure literal;
3. a **closure literal after it** in the same scope, with the same function
   type. The type is part of the mangled name, so closures of different types
   do not collide.

Only the **first** closure after the macro is affected.

## Evidence: a colliding mangled name

`nm` on the object file, counting `(Box) -> Bool` closures in two functions that
differ only in where a closure sits:

| function | closures in source | symbols emitted | discriminators |
|---|---|---|---|
| `ordering` (wrong) | 4 | **3** | `U0_`, `U1_`, `U2_` |
| `beforeAndAfter` (right) | 3 | 3 | `U_`, `U0_`, `U1_` |

```
nm <obj> | awk '{print $NF}' | grep "8ordering.*Sb.*3Box.*XEfU" | sort -u
```

In the failing case the macro's closure and the first following closure land on
one mangled name, so only one body is emitted and both call sites bind to it.
Note the numbering starts at `U0_` — the bare `U_` slot is where the two
overlapped.

## Why it looks like memory corruption at first

Anything that shifts closure numbering masks it, which makes the bug appear to
depend on observation rather than on code:

- Adding a `print` before the assertion makes it pass. String interpolation and
  default arguments introduce implicit closures that bump the counter.
- Declaring any closure *before* the macro makes it pass (`beforeAndAfter`).
- Rewriting the predicate from `if case` to `switch` appears to fix it, but does
  not: the `switch` form is equally corrupted when it is the first closure after
  the macro (`w5SwitchFilter` in the bisection). It only looked like a fix
  because in the original test it was second.

It is deterministic: `--no-parallel` behaves identically, so it is not a race.

## Blast radius

**The library cannot be affected.** `Sources/` uses no macros at all —
freestanding or attached — and the trigger requires a macro expansion:

```sh
grep -rnoE '#[a-zA-Z_][a-zA-Z0-9_]*\(' Sources/ \
  | grep -vE '#(if|else|endif|available|selector|file|line|function|column|keyPath|sourceLocation)'
```

**No test currently has the pattern.** The danger is not a failing test but a
false-green one — a corrupted predicate that happens to leave the assertion
true. The scanner below finds the at-risk shape (macro carrying a closure,
followed by another closure in the same test body, handling multi-line macro
invocations). It was validated against both known-bad cases and reports nothing
across `Tests/`. Re-run it when adding tests:

```python
import io, re, glob
closure_re = re.compile(r'\{\s*(\$0|[a-z][A-Za-z0-9]*\s+in\b|if case|switch)')
macro_re = re.compile(r'#(expect|require)\(')

def scan(path):
    lines = io.open(path, encoding="utf-8").read().split("\n")
    func_name, i, macro_hit = None, 0, None
    while i < len(lines):
        line = lines[i]
        m = re.search(r'func\s+(\w+)\s*\(', line)
        if m and "@Test" in ((lines[i - 1] if i >= 1 else "") + line):
            func_name, macro_hit = m.group(1), None
        if func_name is None:
            i += 1
            continue
        mm = macro_re.search(line)
        if mm:                      # consume the whole invocation across lines
            depth, started, text, j = 0, False, [], i
            for j in range(i, len(lines)):
                text.append(lines[j])
                for ch in (lines[j][mm.end() - 1:] if j == i else lines[j]):
                    if ch == '(':
                        depth, started = depth + 1, True
                    elif ch == ')':
                        depth -= 1
                if started and depth <= 0:
                    break
            macro_hit = (i + 1, j + 1) if closure_re.search("\n".join(text)) else None
            i = j + 1
            continue
        if macro_hit and closure_re.search(line):
            print(f"AT RISK {path}:{macro_hit[0]}-{macro_hit[1]} [{func_name}]"
                  f" -> closure at line {i + 1}")
            macro_hit = None
        i += 1

for p in sorted(glob.glob("Tests/**/*.swift", recursive=True)):
    scan(p)
```

## Working around it

Any one of these is enough, but the first is the only one that is robust rather
than incidental:

- **Do not put a closure literal inside `#expect` / `#require`.** Bind the value
  first and assert on the binding. This is what `RetrievalTests.swift` and
  `AliasTests.swift` do.
- Declaring a closure before the macro, or reordering so the affected closure is
  not first, also works — but both depend on numbering that any later edit can
  shift, so they are not worth relying on.

## A separate observation, not investigated

In `AliasTests.swift`, `#expect(try store.aliases().isEmpty)` inside a
`withStore { ... }` closure failed to compile with *"errors thrown from here are
not handled"*, even though the enclosing closure is throwing and earlier `try`
expressions in the same file are accepted. Hoisting the `try` out of the macro
fixes it. This may share a root cause with the above — both involve macro
expansion interacting with an enclosing closure — but that was not established.
