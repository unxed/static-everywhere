#!/usr/bin/env bash
# publish-release.sh -- publish what pack-release.sh produced as the
# rolling GitHub release TAG, pointing at the commit that was built.
#
# One release per program, replaced by every green run: the download URL
#   https://github.com/<repo>/releases/download/<TAG>/<asset>
# stays the same, so README can link to it. Releases are marked prerelease
# so that none of the programs claims the repository-wide "Latest" badge.
#
# The old release and its tag are deleted and recreated rather than
# edited, because a tag cannot be moved through `gh release edit`, and a
# release left on an old tag would claim the wrong source. The download
# is unavailable for the seconds between delete and create.
#
# Usage (in the release job, with GH_TOKEN and GH_REPO set):
#   publish-release.sh --tag TAG --dir DIR
#
# DIR must contain exactly one *.tar.gz, its .sha256, release-title.txt
# and release-notes.md. The target commit is $GITHUB_SHA.
set -euo pipefail

die() { printf 'publish-release.sh: %s\n' "$*" >&2; exit 1; }

tag='' dir=''
while [ $# -gt 0 ]; do
    case $1 in
        --tag) [ $# -ge 2 ] || die "--tag needs a value"; tag=$2; shift 2 ;;
        --dir) [ $# -ge 2 ] || die "--dir needs a value"; dir=$2; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$tag" ] || die "--tag is required"
[ -n "$dir" ] || die "--dir is required"
[ -n "${GH_REPO:-}" ]    || die "GH_REPO is not set"
[ -n "${GITHUB_SHA:-}" ] || die "GITHUB_SHA is not set"
printf '%s' "$GITHUB_SHA" | grep -Eq '^[0-9a-f]{40}$' \
    || die "GITHUB_SHA is not a full commit id: $GITHUB_SHA"

shopt -s nullglob
tarballs=("$dir"/*.tar.gz)
shopt -u nullglob
[ ${#tarballs[@]} -eq 1 ] \
    || die "expected exactly one .tar.gz in $dir, found ${#tarballs[@]}"
tarball=${tarballs[0]}
for f in "$tarball.sha256" "$dir/release-title.txt" "$dir/release-notes.md"; do
    [ -s "$f" ] || die "missing or empty: $f"
done
# The checksum file names the asset relative to its own directory.
(cd "$dir" && sha256sum --check --quiet -- "$(basename -- "$tarball").sha256") \
    || die "checksum does not match: $tarball"
title=$(head -n 1 "$dir/release-title.txt")

if gh release view "$tag" >/dev/null 2>&1; then
    printf 'publish-release.sh: replacing release %s\n' "$tag"
    gh release delete "$tag" --cleanup-tag --yes
fi
# A tag can outlive its release (deleting a release in the web UI keeps
# the tag). `gh release create --target` would then silently reuse the
# old tag and publish new binaries under old source.
if gh api "repos/$GH_REPO/git/ref/tags/$tag" >/dev/null 2>&1; then
    printf 'publish-release.sh: deleting tag %s left without a release\n' "$tag"
    gh api -X DELETE "repos/$GH_REPO/git/refs/tags/$tag" >/dev/null
fi

gh release create "$tag" "$tarball" "$tarball.sha256" \
    --target "$GITHUB_SHA" \
    --title "$title" \
    --notes-file "$dir/release-notes.md" \
    --prerelease

# Prove the claim the release makes: its tag is the commit that was built.
read -r obj_type obj_sha < <(gh api "repos/$GH_REPO/git/ref/tags/$tag" \
    --jq '.object.type + " " + .object.sha')
if [ "$obj_type" = tag ]; then
    obj_sha=$(gh api "repos/$GH_REPO/git/tags/$obj_sha" --jq '.object.sha')
fi
[ "$obj_sha" = "$GITHUB_SHA" ] \
    || die "tag $tag points at $obj_sha, not the built commit $GITHUB_SHA"

printf 'publish-release.sh: published %s at %s\n' "$tag" "$GITHUB_SHA"
printf '  %s/%s/releases/download/%s/%s\n' \
    "${GITHUB_SERVER_URL:-https://github.com}" "$GH_REPO" "$tag" "$(basename -- "$tarball")"
