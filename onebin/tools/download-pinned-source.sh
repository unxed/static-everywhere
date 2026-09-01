#!/usr/bin/env bash
# Shared downloader for immutable source archives recorded in a lock file.
#
# The caller supplies the lock entry and the final archive path. A download
# is published only after its checksum passes, so a failed or interrupted
# transfer can never become a seemingly usable cache hit on the next run.

download_pinned_archive() {
    local name=$1 version=$2 sha=$3 url=$4 archive=$5 tmp

    if [ -f "${archive}" ] && \
        printf '%s  %s\n' "${sha}" "${archive}" \
            | sha256sum --check --status -; then
        return 0
    fi
    if [ -f "${archive}" ]; then
        echo "download-pinned-source.sh: cached ${name} ${version} failed checksum; refetching" >&2
    fi

    tmp=$(mktemp "${archive}.download.XXXXXX")
    if ! curl --fail --location \
        --retry 8 --retry-all-errors --retry-delay 5 --retry-max-time 300 \
        --silent --show-error --output "${tmp}" "${url}"; then
        rm -f -- "${tmp}"
        echo "download-pinned-source.sh: failed to download ${name} ${version}" >&2
        return 1
    fi
    if ! printf '%s  %s\n' "${sha}" "${tmp}" \
        | sha256sum --check --status -; then
        rm -f -- "${tmp}"
        echo "download-pinned-source.sh: sha256 mismatch for ${name} ${version}" >&2
        return 1
    fi
    mv -f -- "${tmp}" "${archive}"
}
