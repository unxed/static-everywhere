#!/usr/bin/env bash
# pack-release.sh -- turn a finished, smoke-tested build into the archive
# that is published as a GitHub release asset.
#
# Why a tarball, and why in the build job
# ---------------------------------------
# A CI artifact is not something "anyone" can download: it needs a GitHub
# login and expires after retention-days. It is also not the tree the
# smoke test ran. upload-artifact stores zipped files as 644 and follows
# symlinks, so a downloaded bundle has lost every executable bit, and
# GNOME Terminal's usr/bin/gnome-terminal -> ../../gnome-terminal (or
# far2l's lib/far2l/far2l_askpass -> ../../bin/far2l) arrives as a copy.
#
# A tar made here, in the job that has just built, audited and smoke-tested
# the tree, keeps modes and links. The release job only moves this file;
# it never repacks it, so what is published is what was tested.
#
# Usage:
#   pack-release.sh --name NAME --out DIR --title TEXT --run TEXT
#                   [--lock FILE]... [--note TEXT]... SRC=DEST...
#
#   SRC=DEST   copy SRC (file or directory) to NAME/DEST in the archive.
#              DEST "." puts the contents of directory SRC directly
#              under NAME/.
#   --title    release title.
#   --run      the command that starts the program after `tar xzf`,
#              relative to the directory the archive was unpacked in.
#   --lock     a repository-relative pin file; copied into BUILD-INFO.txt
#              and linked from the release notes at the exact commit.
#              At least one is required.
#   --note     an extra line for BUILD-INFO.txt and the notes, e.g. an
#              upstream commit that is not recorded in a lock file.
#
# Writes into DIR (which must not exist or be empty):
#   NAME-linux-x86_64.tar.gz         the archive, top-level directory NAME/
#   NAME-linux-x86_64.tar.gz.sha256  sha256sum format
#   release-title.txt, release-notes.md   read by publish-release.sh
#
# Refuses a tree containing an absolute symlink, a symlink that leaves
# NAME/, or a dangling one: each of those works on the runner, where the
# absolute CI paths exist, and breaks after unpacking anywhere else.
set -euo pipefail

die() { printf 'pack-release.sh: %s\n' "$*" >&2; exit 1; }

name='' out='' title='' run_hint=''
locks=() notes=() items=()
while [ $# -gt 0 ]; do
    case $1 in
        --name)  [ $# -ge 2 ] || die "--name needs a value";  name=$2;     shift 2 ;;
        --out)   [ $# -ge 2 ] || die "--out needs a value";   out=$2;      shift 2 ;;
        --title) [ $# -ge 2 ] || die "--title needs a value"; title=$2;    shift 2 ;;
        --run)   [ $# -ge 2 ] || die "--run needs a value";   run_hint=$2; shift 2 ;;
        --lock)  [ $# -ge 2 ] || die "--lock needs a value";  locks+=("$2"); shift 2 ;;
        --note)  [ $# -ge 2 ] || die "--note needs a value";  notes+=("$2"); shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        --*) die "unknown option: $1" ;;
        *=*) items+=("$1"); shift ;;
        *) die "expected SRC=DEST, got: $1" ;;
    esac
done
[ -n "$name" ]     || die "--name is required"
[ -n "$out" ]      || die "--out is required"
[ -n "$title" ]    || die "--title is required"
[ -n "$run_hint" ] || die "--run is required"
[ ${#items[@]} -gt 0 ] || die "nothing to pack: give at least one SRC=DEST"
# A binary nobody can trace to its sources is not something to publish.
[ ${#locks[@]} -gt 0 ] || die "at least one --lock is required"
case $name in
    *[!A-Za-z0-9._-]*|.*) die "--name must be [A-Za-z0-9._-] and not start with a dot: $name" ;;
esac
for lock in "${locks[@]}"; do
    case $lock in /*) die "--lock must be repository-relative: $lock" ;; esac
    [ -f "$lock" ] || die "lock file not found: $lock"
done
if [ -e "$out" ] && [ -n "$(ls -A -- "$out")" ]; then
    die "output directory is not empty: $out"
fi

asset="${name}-linux-x86_64.tar.gz"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage"

for item in "${items[@]}"; do
    src=${item%%=*}
    dest=${item#*=}
    [ -n "$src" ] && [ -n "$dest" ] || die "empty side in SRC=DEST: $item"
    case $dest in /*|..|../*|*/..|*/../*) die "DEST must stay inside $name/: $item" ;; esac
    [ -e "$src" ] || [ -L "$src" ] || die "missing build output: $src"
    if [ "$dest" = . ]; then
        [ -d "$src" ] || die "DEST \".\" needs a directory: $src"
        cp -a -- "$src/." "$stage/"
    else
        mkdir -p -- "$(dirname -- "$stage/$dest")"
        cp -a -- "$src" "$stage/$dest"
    fi
done

# Links must survive being unpacked somewhere else.
stage_real=$(realpath -- "$stage")
bad_links=()
while IFS= read -r -d '' link; do
    target=$(readlink -- "$link")
    rel=${link#"$stage"/}
    case $target in
        /*) bad_links+=("$rel -> $target (absolute)"); continue ;;
    esac
    resolved=$(realpath -m -- "$(dirname -- "$link")/$target")
    case $resolved/ in
        "$stage_real"/*) ;;
        *) bad_links+=("$rel -> $target (leaves $name/)"); continue ;;
    esac
    [ -e "$link" ] || bad_links+=("$rel -> $target (dangling)")
done < <(find "$stage" -type l -print0)
if [ ${#bad_links[@]} -gt 0 ]; then
    printf 'pack-release.sh: symlinks that break once the archive is unpacked elsewhere:\n' >&2
    printf '  %s\n' "${bad_links[@]}" >&2
    exit 1
fi

server=${GITHUB_SERVER_URL:-https://github.com}
repo=${GITHUB_REPOSITORY:-unxed/static-everywhere}
sha=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
commit_url="$server/$repo/commit/$sha"
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    run_url="$server/$repo/actions/runs/$GITHUB_RUN_ID"
else
    run_url='(not built in GitHub Actions)'
fi
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
    printf '%s\n\n' "$title"
    printf 'built from:   %s\n' "$commit_url"
    printf 'workflow run: %s\n' "$run_url"
    printf 'built at:     %s\n' "$built_at"
    printf 'start with:   %s\n' "$run_hint"
    for note in "${notes[@]}"; do
        printf '%s\n' "$note"
    done
    printf '\nThe build recipe is the static-everywhere tree at the commit above;\n'
    printf 'the pin files below name every upstream source it builds.\n'
    for lock in "${locks[@]}"; do
        printf '\n===== %s =====\n' "$lock"
        cat -- "$lock"
    done
} >"$stage/BUILD-INFO.txt"

mkdir -p "$out"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -C "$work" -czf "$out/$asset" "$name"
(cd "$out" && sha256sum -- "$asset" >"$asset.sha256")

printf '%s\n' "$title" >"$out/release-title.txt"
{
    printf 'Built from [`%s`](%s)' "${sha:0:12}" "$commit_url"
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
        printf ' by [workflow run %s](%s)' "$GITHUB_RUN_ID" "$run_url"
    fi
    printf ', %s. Linux x86_64.\n\n' "$built_at"
    printf '```sh\n'
    printf 'tar xzf %s\n' "$asset"
    printf '%s\n' "$run_hint"
    printf '```\n\n'
    for note in "${notes[@]}"; do
        printf '%s  \n' "$note"
    done
    [ ${#notes[@]} -eq 0 ] || printf '\n'
    printf 'Upstream sources are pinned in'
    sep=' '
    for lock in "${locks[@]}"; do
        printf '%s[`%s`](%s/%s/blob/%s/%s)' "$sep" "$lock" "$server" "$repo" "$sha" "$lock"
        sep=', '
    done
    printf '; the build recipe is the *Source code* archive of this release.\n'
    printf '`BUILD-INFO.txt` inside the archive carries the same information.\n\n'
    printf 'Every successful run of this workflow on the default branch replaces this release.\n'
} >"$out/release-notes.md"

printf 'pack-release.sh: %s/%s (%s)\n' "$out" "$asset" "$(du -h -- "$out/$asset" | cut -f1)"
