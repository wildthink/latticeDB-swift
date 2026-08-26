#!/usr/bin/env bash
set -euo pipefail

repository="${1:?usage: $0 repository version source-dir package-dir}"
version="${2:?missing version}"
source_dir="${3:?missing source dir}"
package_dir="${4:?missing package dir}"
tag="v$version"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' "VERSION must use semantic version form x.y.z, got: $version" >&2
  exit 2
fi

if [[ ! -d "$source_dir/.git" ]]; then
  git clone --branch "$tag" --depth 1 "$repository" "$source_dir"
else
  git -C "$source_dir" fetch --tags origin
  git -C "$source_dir" switch --detach "$tag"
fi

actual_version="$(sed -nE 's/^const version = "([^"]+)";.*/\1/p' "$source_dir/build.zig")"
if [[ "$actual_version" != "$version" ]]; then
  printf '%s\n' "Tag $tag declares LatticeDB $actual_version, not $version." >&2
  exit 2
fi

revision="$(git -C "$source_dir" rev-parse HEAD)"
bash "$package_dir/Scripts/sync-lattice-header.sh" "$source_dir" "$package_dir"

cat >"$package_dir/Native/LatticeDB.lock" <<EOF
LATTICE_UPSTREAM_REPOSITORY := $repository
LATTICE_UPSTREAM_VERSION := $version
LATTICE_UPSTREAM_REF := $tag
LATTICE_UPSTREAM_REVISION := $revision
EOF

perl -0pi -e "s/public static let nativeVersion = \"[^\"]+\"/public static let nativeVersion = \"$version\"/" \
  "$package_dir/Sources/LatticeDB/LatticeDB.swift"

printf '%s\n' "Updated native lock and headers to LatticeDB $tag ($revision)."
printf '%s\n' 'Run `make verify-native`, `make test`, review the upstream release, then commit the upgrade.'
