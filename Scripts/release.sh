#!/usr/bin/env bash
#
# Builds a release ClipDroid.app and packages it as dist/ClipDroid-<version>.dmg.
#
#   Scripts/release.sh                 # tested, release build, signed, in a .dmg
#   Scripts/release.sh --notarize      # also notarized and stapled (needs DEVELOPER_ID, NOTARY_PROFILE)
#   Scripts/release.sh --allow-dirty   # build from uncommitted changes anyway
#
# The building, signing and disk-image work is all bundle.sh's; this adds the checks that make
# the result fit to hand to someone. The version comes from the latest git tag and the build
# number from the commit count, so tag first (`git tag v1.0.0`) for a meaningful version.
set -euo pipefail

NOTARIZE=0
ALLOW_DIRTY=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        *) echo "error: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The build number is the commit count, so a build from uncommitted changes carries the number of
# a commit that does not contain them — two different apps claiming to be the same build.
if [[ "$ALLOW_DIRTY" -eq 0 && -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "error: the working tree has uncommitted changes." >&2
    echo "       Commit them first, or pass --allow-dirty." >&2
    exit 1
fi

echo "Running tests..."
swift test --package-path "$ROOT" --quiet

BUNDLE_ARGS=(release --dmg)
[[ "$NOTARIZE" -eq 1 ]] && BUNDLE_ARGS+=(--notarize)
"$ROOT/Scripts/bundle.sh" "${BUNDLE_ARGS[@]}"

DMG="$(ls -t "$ROOT"/dist/ClipDroid-*.dmg | head -1)"
hdiutil verify -quiet "$DMG"
echo
echo "Release ready: $DMG ($(du -h "$DMG" | cut -f1))"
