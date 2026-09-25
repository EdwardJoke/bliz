#!/usr/bin/env bash
#
# Gate for the release pipeline: every place a version is written down must agree.
#
# A release stamps a version into a filename (`bliz-0.4.0-aarch64-macos.tar.gz`)
# while the binary inside that tarball reports its own version from a constant in
# `src/main.zig`. When those disagree nothing fails — you publish a tarball whose
# name contradicts its contents, and you find out from a bug report. The two
# labels in this repo had already drifted a release apart once before this check
# existed, which is why it is a gate and not a warning.
#
# Usage:
#   scripts/release-check.sh v0.4.0
#
# When ZIG_VERSION is set in the environment (the release workflow pins it) it
# must equal build.zig.zon's `.minimum_zig_version`. That matters because
# vercel-labs/setup-zig takes an explicit version and cannot read the field
# itself, so the pin is otherwise free to drift away from the declared minimum.

set -euo pipefail

tag="${1:-}"
if [ -z "$tag" ]; then
    echo "usage: release-check.sh <tag>    e.g. release-check.sh v0.4.0" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

case "$tag" in
v*) want="${tag#v}" ;;
*)
    echo "::error::tag '$tag' does not start with 'v'; releases are tagged v<semver>, e.g. v0.4.0" >&2
    exit 1
    ;;
esac

# `const version = "0.4.0";` — src/main.zig, at column zero.
cli_version="$(sed -n 's/^const version = "\(.*\)";$/\1/p' src/main.zig | head -1)"
# `.version = "0.4.0",` — build.zig.zon. Note this cannot match
# `.minimum_zig_version`, which starts with `.minimum`.
pkg_version="$(sed -n 's/^[[:space:]]*\.version = "\(.*\)",$/\1/p' build.zig.zon | head -1)"
# `.minimum_zig_version = "0.16.0",`
min_zig="$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\(.*\)",$/\1/p' build.zig.zon | head -1)"

# A parse that silently finds nothing is worse than a wrong one: comparing two
# empty strings passes. So treat an empty result as a failure to look at all —
# otherwise editing one of these labels into a format the pattern misses would
# quietly disable the check it is guarding.
for pair in "src/main.zig:cli_version" "build.zig.zon:pkg_version" "build.zig.zon:min_zig"; do
    file="${pair%%:*}"
    name="${pair##*:}"
    if [ -z "${!name}" ]; then
        echo "::error::could not read a version out of $file (looked for $name) — did the label move or get reformatted?" >&2
        exit 1
    fi
done

printf '%-30s %s\n' "tag" "$tag"
printf '%-30s %s\n' "src/main.zig   const version" "$cli_version"
printf '%-30s %s\n' "build.zig.zon  .version" "$pkg_version"
printf '%-30s %s\n' "               .minimum_zig_version" "$min_zig"
printf '%-30s %s\n' "setup-zig pin  ZIG_VERSION" "${ZIG_VERSION:-<unset>}"

status=0
check() {
    what="$1"
    got="$2"
    expected="$3"
    if [ "$got" = "$expected" ]; then
        printf '  ok    %s\n' "$what"
    else
        printf '  FAIL  %s: %s, expected %s\n' "$what" "$got" "$expected"
        echo "::error::$what is '$got' but should be '$expected'"
        status=1
    fi
}

check "tag matches src/main.zig" "$cli_version" "$want"
check "tag matches build.zig.zon" "$pkg_version" "$want"
if [ -n "${ZIG_VERSION:-}" ]; then
    check "ZIG_VERSION matches .minimum_zig_version" "$min_zig" "$ZIG_VERSION"
fi

if [ "$status" -ne 0 ]; then
    printf '\nVersion labels disagree — bump them together, or retag.\n' >&2
    exit 1
fi

printf '\nall version labels agree\n'
