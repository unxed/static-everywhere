#!/usr/bin/env bash
# Regression test for the source-archive download boundary. It covers the
# failure class rather than a particular dependency: failed transfers must
# not leave a cache-looking file, and an invalid cached archive must be
# replaced only by a fully downloaded, checksum-verified archive.

set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=onebin/tools/download-pinned-source.sh
source "${SCRIPT_DIR}/../onebin/tools/download-pinned-source.sh"

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
mkdir -p "${PROBE}/bin" "${PROBE}/cache"

cat >"${PROBE}/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=
expect_output=0
for arg in "$@"; do
    if [ "${expect_output}" -eq 1 ]; then
        output=${arg}
        expect_output=0
    elif [ "${arg}" = '--output' ]; then
        expect_output=1
    fi
done
[ -n "${output}" ]
printf '%s\n' "$*" >> "${FAKE_CURL_ARGS_LOG}"
case "${FAKE_CURL_MODE}" in
    fail)
        printf '%s\n' partial > "${output}"
        exit 22
        ;;
    success)
        printf '%s\n' expected-payload > "${output}"
        ;;
    *)
        echo "unknown FAKE_CURL_MODE=${FAKE_CURL_MODE}" >&2
        exit 2
        ;;
esac
CURL
chmod 755 "${PROBE}/bin/curl"

archive=${PROBE}/cache/example.tar.gz
args_log=${PROBE}/curl-args.log
export PATH="${PROBE}/bin:${PATH}"
export FAKE_CURL_ARGS_LOG=${args_log}
expected_sha=$(printf '%s\n' expected-payload | sha256sum | awk '{print $1}')

set +e
FAKE_CURL_MODE=fail download_pinned_archive \
    example 1.0 "${expected_sha}" https://example.invalid/example.tar.gz "${archive}"
status=$?
set -e
[ "${status}" -ne 0 ]
[ ! -e "${archive}" ]
if find "${PROBE}/cache" -maxdepth 1 -name 'example.tar.gz.download.*' \
    -print -quit | grep -q .; then
    echo 'failed transfer left a temporary archive behind' >&2
    exit 1
fi

FAKE_CURL_MODE=success download_pinned_archive \
    example 1.0 "${expected_sha}" https://example.invalid/example.tar.gz "${archive}"
[ "$(<"${archive}")" = expected-payload ]
grep -F -- '--retry 8' "${args_log}"
grep -F -- '--retry-all-errors' "${args_log}"
grep -F -- '--retry-max-time 300' "${args_log}"

printf '%s\n' stale > "${archive}"
FAKE_CURL_MODE=success download_pinned_archive \
    example 1.0 "${expected_sha}" https://example.invalid/example.tar.gz "${archive}"
[ "$(<"${archive}")" = expected-payload ]

printf '%s\n' 'pinned source download tests passed'
