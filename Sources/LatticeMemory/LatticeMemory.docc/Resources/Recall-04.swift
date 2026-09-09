let history = try store.history(of: "package.manager", in: acme)
print(history.map(\.value))
// [string("npm"), string("pnpm")] — newest first

let lastWeek = Date().addingTimeInterval(-7 * 86_400)
let thenHeld = try store.assertions(validAt: lastWeek, in: acme)
