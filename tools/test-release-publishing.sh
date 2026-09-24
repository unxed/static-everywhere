#!/usr/bin/env bash
# Preflight test for tools/pack-release.sh and tools/publish-release.sh.
#
# Why this exists
# ---------------
# Both scripts run only after a build that takes one to five hours. A
# typo in either would turn a green build into a failed release and cost
# another full run; here it costs a second, before anything is compiled.
#
# What it pins down:
#   - the archive keeps executable bits and relative symlinks, which a
#     zipped CI artifact loses -- the reason the archive exists at all;
#   - absolute, escaping and dangling symlinks are refused, because they
#     only work on the runner that built the tree;
#   - the release is recreated on the built commit, a stale tag is
#     removed first, and a tag on any other commit fails the job.
# gh is replaced by a stub that records its calls; nothing reaches GitHub.
set -euo pipefail
# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACK="$SCRIPT_DIR/pack-release.sh"
PUBLISH="$SCRIPT_DIR/publish-release.sh"

fail() { printf 'test-release-publishing: FAIL: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cd "$tmp"

export GITHUB_SERVER_URL=https://github.com
export GITHUB_REPOSITORY=example/static-everywhere
export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
export GITHUB_RUN_ID=42

# --- a bundle shaped like the real ones ----------------------------------
mkdir -p contrib/demo bundle/usr/bin bundle/share
printf 'demo 1.0 %s https://example.invalid/demo.git\n' "$GITHUB_SHA" >contrib/demo/deps.lock
printf '#!/bin/sh\necho demo\n' >bundle/demo
chmod 755 bundle/demo
ln -s ../../demo bundle/usr/bin/demo
printf 'data\n' >bundle/share/data.txt
chmod 644 bundle/share/data.txt
printf '#!/bin/sh\n' >helper.sh
chmod 755 helper.sh

pack_demo() {  # $1 = out dir, rest = extra SRC=DEST
    local out=$1; shift
    "$PACK" --name demo --out "$out" --title 'Demo 1.0' \
        --run './demo/demo' --lock contrib/demo/deps.lock \
        --note 'demo: https://example.invalid/demo/commit/abc' \
        bundle=. "$@"
}

pack_demo out helper.sh=tools/helper.sh >/dev/null
for f in demo-linux-x86_64.tar.gz demo-linux-x86_64.tar.gz.sha256 \
         release-title.txt release-notes.md; do
    [ -s "out/$f" ] || fail "pack did not write out/$f"
done
(cd out && sha256sum --check --quiet demo-linux-x86_64.tar.gz.sha256) \
    || fail "checksum file does not verify"

mkdir x
tar -xzf out/demo-linux-x86_64.tar.gz -C x
[ "$(ls x)" = demo ] || fail "archive top level is not the single directory demo/"
[ -x x/demo/demo ] || fail "executable bit lost on demo/demo"
[ -x x/demo/tools/helper.sh ] || fail "executable bit lost on a single-file item"
[ -L x/demo/usr/bin/demo ] || fail "symlink became a copy"
[ "$(readlink x/demo/usr/bin/demo)" = ../../demo ] || fail "symlink target changed"
[ "$(x/demo/usr/bin/demo)" = demo ] || fail "unpacked symlink does not run the program"
[ "$(stat -c %a x/demo/share/data.txt)" = 644 ] || fail "data file mode changed"
grep -Fq 'demo 1.0 ' x/demo/BUILD-INFO.txt || fail "BUILD-INFO.txt lacks the lock file"
grep -Fq "commit/$GITHUB_SHA" x/demo/BUILD-INFO.txt || fail "BUILD-INFO.txt lacks the commit"
grep -Fq 'demo: https://example.invalid/demo/commit/abc' x/demo/BUILD-INFO.txt \
    || fail "BUILD-INFO.txt lacks the --note line"
[ "$(cat out/release-title.txt)" = 'Demo 1.0' ] || fail "wrong release title"
grep -Fq './demo/demo' out/release-notes.md || fail "notes lack the start command"
grep -Fq "blob/$GITHUB_SHA/contrib/demo/deps.lock" out/release-notes.md \
    || fail "notes do not link the lock file at the built commit"
grep -Fq 'actions/runs/42' out/release-notes.md || fail "notes do not link the run"

expect_pack_failure() {  # $1 = what, $2 = expected message, rest = pack args
    local what=$1 msg=$2; shift 2
    rm -rf bad-out
    if "$@" >bad.log 2>&1; then
        fail "pack accepted $what"
    fi
    grep -Fq "$msg" bad.log || { cat bad.log >&2; fail "pack refused $what for another reason"; }
}

ln -s /etc/passwd bundle/abs
expect_pack_failure 'an absolute symlink' '(absolute)' pack_demo bad-out
rm bundle/abs
ln -s ../../../../outside bundle/usr/bin/escape
expect_pack_failure 'a symlink leaving the tree' '(leaves demo/)' pack_demo bad-out
rm bundle/usr/bin/escape
ln -s no-such-file bundle/dangling
expect_pack_failure 'a dangling symlink' '(dangling)' pack_demo bad-out
rm bundle/dangling
expect_pack_failure 'a missing build output' 'missing build output' \
    pack_demo bad-out no-such-dir=x
expect_pack_failure 'a DEST outside the tree' 'must stay inside' \
    pack_demo bad-out helper.sh=../helper.sh
expect_pack_failure 'a non-empty output directory' 'not empty' pack_demo out
expect_pack_failure 'a missing --lock' 'at least one --lock' \
    "$PACK" --name demo --out bad-out --title t --run r bundle=.

# --- publish, against a stub gh ------------------------------------------
mkdir stubbin
cat >stubbin/gh <<'STUB'
#!/usr/bin/env bash
# Records each call; state comes from STUB_* variables.
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
    'release view')   [ "${STUB_RELEASE:-0}" = 1 ] ;;
    'release delete') exit 0 ;;
    'release create') exit 0 ;;
    'api -X')         exit 0 ;;
    api\ *)
        if [ "$#" -ge 3 ] && [ "$3" = --jq ]; then
            printf 'commit %s\n' "${STUB_TAG_SHA:-$GITHUB_SHA}"
        else
            [ "${STUB_STALE_TAG:-0}" = 1 ]
        fi ;;
    *) printf 'stub gh: unexpected call: %s\n' "$*" >&2; exit 2 ;;
esac
STUB
chmod +x stubbin/gh
export PATH="$tmp/stubbin:$PATH" GH_REPO=example/static-everywhere
export STUB_LOG="$tmp/gh.log"

run_publish() { : >"$STUB_LOG"; "$PUBLISH" --tag demo-latest --dir out; }

STUB_RELEASE=0 run_publish >/dev/null
grep -q '^release delete' "$STUB_LOG" && fail "deleted a release that did not exist"
grep -Fq 'release create demo-latest out/demo-linux-x86_64.tar.gz out/demo-linux-x86_64.tar.gz.sha256' "$STUB_LOG" \
    || fail "did not upload the tarball and its checksum"
grep -Fq -- "--target $GITHUB_SHA" "$STUB_LOG" || fail "release not targeted at GITHUB_SHA"
grep -Fq -- '--prerelease' "$STUB_LOG" || fail "release not marked prerelease"

STUB_RELEASE=1 run_publish >/dev/null
grep -Fq 'release delete demo-latest --cleanup-tag --yes' "$STUB_LOG" \
    || fail "old release and its tag were not deleted"

STUB_STALE_TAG=1 run_publish >/dev/null
grep -Fq 'api -X DELETE repos/example/static-everywhere/git/refs/tags/demo-latest' "$STUB_LOG" \
    || fail "a tag left without a release was not deleted"

if STUB_TAG_SHA=ffffffffffffffffffffffffffffffffffffffff run_publish >pub.log 2>&1; then
    fail "publish accepted a tag on a commit other than GITHUB_SHA"
fi
grep -Fq 'not the built commit' pub.log || { cat pub.log >&2; fail "wrong failure for a mismatched tag"; }

printf 'broken\n' >>out/demo-linux-x86_64.tar.gz
if run_publish >pub.log 2>&1; then
    fail "publish accepted a tarball that does not match its checksum"
fi

printf 'release publishing: archive keeps modes and links, bad links refused, tag checked\n'
