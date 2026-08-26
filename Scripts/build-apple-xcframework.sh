#!/usr/bin/env bash
set -euo pipefail

# Build universal macOS static LatticeDB and package its C API as an XCFramework.
source_dir="${1:?usage: $0 /path/to/latticedb}"
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

build_slice() {
  local arch="$1"
  local prefix="$work_dir/$arch"
  (cd "$source_dir" && zig build -Doptimize=ReleaseFast -Dtarget="${arch}-macos" --prefix "$prefix")
}

arm_prefix="$work_dir/aarch64"
x86_prefix="$work_dir/x86_64"
build_slice aarch64
build_slice x86_64
lipo -create \
  "$arm_prefix/lib/liblattice.a" \
  "$x86_prefix/lib/liblattice.a" \
  -output "$work_dir/liblattice.a"
rm -rf "$package_dir/Artifacts/Lattice.xcframework"
xcodebuild -create-xcframework \
  -library "$work_dir/liblattice.a" \
  -headers "$arm_prefix/include" \
  -output "$package_dir/Artifacts/Lattice.xcframework"
bash "$package_dir/Scripts/write-native-provenance.sh" \
  "$source_dir" \
  "$package_dir/Artifacts/Lattice.xcframework" \
  "$package_dir/Sources/CLattice/include/lattice.h" \
  "macos-static-xcframework" \
  "aarch64-macos,x86_64-macos"
