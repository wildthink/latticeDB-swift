#!/usr/bin/env bash
set -euo pipefail

source_dir="${1:?usage: $0 /path/to/latticedb package-dir}"
package_dir="${2:?missing package dir}"
header="$source_dir/include/lattice.h"

if [[ ! -f "$header" ]]; then
  printf '%s\n' "Missing upstream header: $header" >&2
  exit 2
fi

cp "$header" "$package_dir/Sources/CLattice/include/lattice.h"
cp "$header" "$package_dir/Sources/CLatticeApple/include/lattice.h"
printf '%s\n' "Synced lattice.h from $source_dir."
