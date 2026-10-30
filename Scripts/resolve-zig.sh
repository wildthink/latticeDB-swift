#!/usr/bin/env bash
set -euo pipefail

# Print the path to a Zig toolchain that can build the pinned upstream source.
#
# Upstream's build.zig.zon declares a minimum Zig version, but Zig makes
# breaking language and std changes between minors, so a newer toolchain is not
# a usable one: 0.17 renamed the std optimize enum fields and upstream 0.16.0
# fails to even configure under it. Require an exact major.minor match, and
# report what is wrong instead of letting the error surface as a compile error
# inside someone else's build.zig.
source_dir="${1:?usage: $0 /path/to/latticedb}"

required="$(sed -nE 's/^[[:space:]]*\.minimum_zig_version = "([0-9]+\.[0-9]+)\.[0-9]+".*/\1/p' \
  "$source_dir/build.zig.zon")"
test -n "$required" || {
  printf '%s\n' "Could not read .minimum_zig_version from $source_dir/build.zig.zon" >&2
  exit 2
}

# An explicit ZIG is a choice, not a hint: use it or say why it cannot be used,
# rather than quietly building with a different toolchain than was asked for.
if test -n "${ZIG:-}"; then
  resolved="$(command -v "$ZIG")" || {
    printf '%s\n' "ZIG=$ZIG is not executable." >&2
    exit 2
  }
  found="$("$resolved" version)"
  case "$found" in
    "$required".*) printf '%s\n' "$resolved"; exit 0 ;;
  esac
  printf '%s\n' "ZIG=$resolved is Zig $found, but LatticeDB needs Zig $required.x." >&2
  exit 2
fi

# Otherwise: the toolchain on PATH, then the Homebrew keg for the required
# minor, which is keg-only and so never on PATH.
candidates=(zig "/opt/homebrew/opt/zig@$required/bin/zig" "/usr/local/opt/zig@$required/bin/zig")
seen=()
for candidate in "${candidates[@]}"; do
  test -n "$candidate" || continue
  resolved="$(command -v "$candidate" 2>/dev/null)" || continue
  found="$("$resolved" version)"
  case "$found" in
    "$required".*) printf '%s\n' "$resolved"; exit 0 ;;
  esac
  seen+=("$resolved ($found)")
done

printf '%s\n' "LatticeDB $(sed -nE 's/^const version = "([^"]+)";.*/\1/p' "$source_dir/build.zig") needs Zig $required.x." >&2
if test "${#seen[@]}" -gt 0; then
  printf '%s\n' "Found: ${seen[*]}" >&2
fi
printf '%s\n' "Install it (brew install zig@$required) or set ZIG=/path/to/zig." >&2
exit 2
