#!/usr/bin/env bash
set -euo pipefail

source_dir="${1:?usage: $0 source-dir version revision header...}"
expected_version="${2:?missing version}"
expected_revision="${3:?missing revision}"
shift 3

if [[ ! -f "$source_dir/build.zig" ]]; then
  printf '%s\n' "LATTICE_SOURCE must point to an upstream LatticeDB checkout: $source_dir" >&2
  exit 2
fi

actual_revision="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
  printf '%s\n' "LatticeDB revision mismatch: expected $expected_revision, found $actual_revision." >&2
  exit 2
fi

actual_version="$(sed -nE 's/^const version = "([^"]+)";.*/\1/p' "$source_dir/build.zig")"
if [[ "$actual_version" != "$expected_version" ]]; then
  printf '%s\n' "LatticeDB build version mismatch: expected $expected_version, found ${actual_version:-none}." >&2
  exit 2
fi

for header in "$@"; do
  if ! cmp -s "$source_dir/include/lattice.h" "$header"; then
    printf '%s\n' "Vendored header differs from $source_dir/include/lattice.h: $header" >&2
    printf '%s\n' 'Run `make sync-native-header` after intentionally updating the upstream lock.' >&2
    exit 2
  fi
done

printf '%s\n' "Verified LatticeDB $expected_version ($expected_revision)."
