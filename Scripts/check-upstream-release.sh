#!/usr/bin/env bash
set -euo pipefail

repository="${1:?usage: $0 repository pinned-version}"
pinned_version="${2:?missing pinned version}"

latest_tag="$({
  git ls-remote --refs --tags "$repository" 'v[0-9]*'
} | awk -F/ '{print $3}' | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -1)"

if [[ -z "$latest_tag" ]]; then
  printf '%s\n' "No semantic-version release tags found at $repository." >&2
  exit 2
fi

printf '%s\n' "Pinned LatticeDB version: v$pinned_version"
printf '%s\n' "Latest upstream release: $latest_tag"
if [[ "$latest_tag" == "v$pinned_version" ]]; then
  printf '%s\n' 'Upstream is current.'
else
  printf '%s\n' "Update available: $latest_tag. Review it and update Native/LatticeDB.lock deliberately."
fi
