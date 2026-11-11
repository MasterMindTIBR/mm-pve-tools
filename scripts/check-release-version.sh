#!/usr/bin/env bash
# Verify that a release tag is exactly the version in debian/changelog.
set -euo pipefail

if [[ $# -ne 1 || ! $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'usage: %s vX.Y.Z\n' "$0" >&2
    exit 2
fi

version=$(dpkg-parsechangelog -l debian/changelog -SVersion 2>/dev/null) || {
    printf 'could not read debian/changelog\n' >&2
    exit 1
}
version=${version#*:}
version=${version%-*}
expected="v${version}"
if [[ "$1" != "$expected" ]]; then
    printf 'tag %s does not match the debian/changelog version (%s)\n' "$1" "$expected" >&2
    exit 1
fi
printf 'tag %s matches the debian/changelog version\n' "$1"
