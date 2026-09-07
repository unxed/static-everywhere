#!/usr/bin/env bash
# Regression: the audit wrapper must derive internal DT_NEEDED allowances
# from the install prefix instead of naming one observed application library.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/prefix/lib" "$TMP/prefix/bin"
printf 'not an ELF, but a valid prefix member for this wrapper test\n' \
    >"$TMP/prefix/lib/libarbitrary-runtime.so.7"
printf '#!/bin/sh\n' >"$TMP/prefix/bin/konsole"
chmod +x "$TMP/prefix/bin/konsole"

CAPTURE="$TMP/onebin-args"
export CAPTURE
cat >"$TMP/fake-onebin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CAPTURE"
printf '%s\n' '{"result":"fail","counts":{"error":0,"warn":1,"info":0},"findings":[{"id":"OB0060","severity":"warn","subject":"/tmp/libheif/example"}]}'
EOF
chmod +x "$TMP/fake-onebin"

"$REPO_ROOT/tools/audit-with-hygiene-waivers.sh" "$TMP/fake-onebin" \
    --allow-internal-prefix "$TMP/prefix" \
    --max-file 1000000 "$TMP/prefix/bin/konsole" >/dev/null

grep -Fq -- '--allow libarbitrary-runtime.so.7' "$CAPTURE" || {
    printf 'FAIL: internal library basename was not derived from the prefix\n' >&2
    exit 1
}
if grep -Fq -- '--allow-internal-prefix' "$CAPTURE"; then
    printf 'FAIL: wrapper-only prefix option leaked to onebin\n' >&2
    exit 1
fi
grep -Fq -- '--max-file 1000000' "$CAPTURE" || {
    printf 'FAIL: ordinary audit arguments were not passed through\n' >&2
    exit 1
}

printf 'audit internal-prefix regression: PASS\n'
