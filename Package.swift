// swift-tools-version: 6.3

import Foundation
import PackageDescription

let package = Package(
  name: "LatticeDB",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "LatticeDB", targets: ["LatticeDB"]),
    .executable(name: "lattice", targets: ["lattice"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    // LineEditor has not published a release tag yet. Pin to main until a
    // stable version is available, then replace this with a version range.
    .package(url: "https://github.com/wildthink/LineEditor.git", branch: "main"),
  ],
  targets: [
    // Apple releases link the static library inside Artifacts/Lattice.xcframework.
    .target(
      name: "CLatticeApple",
      publicHeadersPath: "include",
      linkerSettings: [
        .unsafeFlags(
          [
            "-L", "Artifacts/Lattice.xcframework/macos-arm64_x86_64",
            "-llattice",
          ], .when(platforms: [.macOS]))
      ]
    ),
    // Linux consumes an installed LatticeDB prefix through the lattice.pc
    // file emitted by the upstream Zig build.
    .systemLibrary(
      name: "CLatticeLinux",
      pkgConfig: "lattice"
    ),
    .target(
      name: "LatticeBridge",
      dependencies: [
        .target(name: "CLatticeApple", condition: .when(platforms: [.macOS])),
        .target(name: "CLatticeLinux", condition: .when(platforms: [.linux])),
      ],
      publicHeadersPath: "include"
    ),
    .target(
      name: "LatticeDB",
      dependencies: [
        "LatticeBridge"
      ]
    ),
    .executableTarget(
      name: "lattice",
      dependencies: [
        "LatticeDB", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "CommandREPL", package: "LineEditor"),
      ]),
    .testTarget(name: "LatticeDBTests", dependencies: ["LatticeDB"]),
  ],
  swiftLanguageModes: [.v6]
)

// The DocC plugin is only needed to build documentation. Adding it
// unconditionally would make every consumer of LatticeDB resolve it and
// SymbolKit as well, so `make docs` opts in through the environment.
if ProcessInfo.processInfo.environment["LATTICE_DOCS"] != nil {
  package.dependencies.append(
    .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.0")
  )
}
