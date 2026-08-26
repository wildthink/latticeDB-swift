#!/usr/bin/env bash
set -euo pipefail

source_dir="${1:?usage: $0 source-dir artifact-dir header artifact-kind targets}"
artifact_dir="${2:?missing artifact dir}"
header="${3:?missing header}"
artifact_kind="${4:?missing artifact kind}"
targets="${5:?missing targets}"

sha256() {
  if command -v shasum >/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

version="$(sed -nE 's/^const version = "([^"]+)";.*/\1/p' "$source_dir/build.zig")"
revision="$(git -C "$source_dir" rev-parse HEAD)"
zig_version="$(zig version)"
header_sha256="$(sha256 "$header")"

cat >"$artifact_dir/Provenance.json" <<EOF
{
  "latticeVersion": "$version",
  "upstreamRevision": "$revision",
  "headerSHA256": "$header_sha256",
  "zigVersion": "$zig_version",
  "artifactKind": "$artifact_kind",
  "targets": "$targets",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

printf '%s\n' "Wrote $artifact_dir/Provenance.json"
