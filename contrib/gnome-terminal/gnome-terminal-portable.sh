#!/usr/bin/env bash
# Run the GNOME Terminal bundle directly from its unpacked directory.
# The wrapper owns the relocation environment and starts a private-name
# GNOME Terminal server, so the standard system D-Bus service cannot select
# the host installation by accident.
set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
BUNDLE_ROOT=$(CDPATH= cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd -P)
CLIENT="${BUNDLE_ROOT}/usr/bin/gnome-terminal.bin"
SERVER="${BUNDLE_ROOT}/usr/libexec/gnome-terminal-server"
SCHEMA_DIR="${BUNDLE_ROOT}/usr/lib/gnome-terminal"
PORTABLE_APP_ID=org.gnome.Terminal.StaticEverywhere

if [ ! -x "$CLIENT" ]; then
    printf 'gnome-terminal portable: bundle is incomplete: %s\n' "$CLIENT" >&2
    exit 1
fi
if [ ! -x "$SERVER" ]; then
    printf 'gnome-terminal portable: bundle is incomplete: %s\n' "$SERVER" >&2
    exit 1
fi
if [ ! -f "$SCHEMA_DIR/gschemas.compiled" ]; then
    printf 'gnome-terminal portable: bundle is incomplete: %s/gschemas.compiled\n' "$SCHEMA_DIR" >&2
    exit 1
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    printf 'gnome-terminal portable: a session D-Bus is required\n' >&2
    exit 1
fi

# These are the only environment changes made by the supported entrypoint.
# In particular, host GTK/GIO modules must not be loaded into the static UI.
export GNOME_TERMINAL_PORTABLE_ROOT="$BUNDLE_ROOT"
export GSETTINGS_SCHEMA_DIR="$SCHEMA_DIR"
export XDG_DATA_DIRS="${BUNDLE_ROOT}/usr/share${XDG_DATA_DIRS:+:${XDG_DATA_DIRS}}"
export PATH="${BUNDLE_ROOT}/usr/bin:${BUNDLE_ROOT}/usr/libexec:${PATH:-/usr/local/bin:/usr/bin:/bin}"
unset GTK_MODULES GTK_PATH GIO_EXTRA_MODULES GDK_PIXBUF_MODULE_FILE

has_name_owner() {
    command -v dbus-send >/dev/null 2>&1 || return 1
    dbus-send --session --print-reply=literal \
        --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.NameHasOwner \
        "string:${PORTABLE_APP_ID}" 2>/dev/null | grep -q 'true'
}

server_pid=
server_started=0

cleanup() {
    status=$?
    if [ "$server_started" -eq 1 ] && [ -n "${server_pid}" ] && \
       kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT

if ! has_name_owner; then
    "$SERVER" --app-id "$PORTABLE_APP_ID" &
    server_pid=$!
    server_started=1

    if command -v dbus-send >/dev/null 2>&1; then
        ready=0
        for _ in $(seq 1 200); do
            if has_name_owner; then
                ready=1
                break
            fi
            if ! kill -0 "$server_pid" 2>/dev/null; then
                wait "$server_pid" || true
                printf 'gnome-terminal portable: bundle server exited before D-Bus registration\n' >&2
                exit 1
            fi
            sleep 0.05
        done
        if [ "$ready" -ne 1 ]; then
            printf 'gnome-terminal portable: timed out waiting for bundle server\n' >&2
            exit 1
        fi
    else
        # dbus-send is a diagnostic utility, not part of the runtime contract.
        # The server has already been started; allow it one scheduling slice.
        sleep 0.2
    fi
fi

"$CLIENT" --app-id "$PORTABLE_APP_ID" "$@"
client_status=$?

# A successful client invocation may only have submitted a new window to the
# server.  Let the server own its normal idle lifetime; killing it here would
# make a regular launch (without --wait) disappear as soon as this wrapper
# exits.  The EXIT trap still tears down the child when startup or the client
# itself fails.
if [ "$client_status" -eq 0 ]; then
    server_started=0
fi
exit "$client_status"
