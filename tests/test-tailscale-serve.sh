#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_DIR/logs"
mkdir -p "$TAILMOX_LOG_DIR" "$TEST_DIR/bin"

source "$TEST_ROOT/tailmox.sh"

cat > "$TEST_DIR/bin/tailscale" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAILMOX_TEST_CALLS"
if [[ "${TAILMOX_TEST_SERVE_MODE:-success}" == "hang" ]]; then
    sleep 10
fi
if [[ "${TAILMOX_TEST_SERVE_MODE:-success}" == "fail" ]]; then
    printf 'mock serve failure\n' >&2
    exit 7
fi
MOCK
chmod +x "$TEST_DIR/bin/tailscale"

cat > "$TEST_DIR/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
shift 2
if [[ "${TAILMOX_TEST_SERVE_MODE:-success}" == "hang" ]]; then
    exit 124
fi
exec "$@"
MOCK
chmod +x "$TEST_DIR/bin/timeout"

export PATH="$TEST_DIR/bin:$PATH"
export TAILMOX_TEST_CALLS="$TEST_DIR/calls"

PASS_COUNT=0
FAIL_COUNT=0

function pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

function fail() {
    printf 'FAIL: %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

: > "$TAILMOX_TEST_CALLS"
TAILMOX_TEST_SERVE_MODE=success
export TAILMOX_TEST_SERVE_MODE
if configure_tailscale_serve https+insecure://localhost:8006 >/dev/null 2>&1 &&
    grep -Fqx 'serve --yes --bg https+insecure://localhost:8006' "$TAILMOX_TEST_CALLS"; then
    pass "Serve runs in the background without interactive prompts"
else
    fail "Serve runs in the background without interactive prompts"
fi

TAILMOX_TEST_SERVE_MODE=fail
export TAILMOX_TEST_SERVE_MODE
if ! configure_tailscale_serve --bg https+insecure://localhost:8006 >/dev/null 2>&1; then
    pass "Serve command failures stop setup"
else
    fail "Serve command failures stop setup"
fi

TAILMOX_TEST_SERVE_MODE=hang
TAILMOX_TAILSCALE_SERVE_TIMEOUT_SECONDS=1
export TAILMOX_TEST_SERVE_MODE TAILMOX_TAILSCALE_SERVE_TIMEOUT_SECONDS
start_time=$SECONDS
if ! configure_tailscale_serve --bg https+insecure://localhost:8006 >/dev/null 2>&1 &&
    (( SECONDS - start_time < 5 )); then
    pass "A stalled Serve command is bounded by a timeout"
else
    fail "A stalled Serve command is bounded by a timeout"
fi

TAILMOX_TAILSCALE_SERVE_TIMEOUT_SECONDS=invalid
export TAILMOX_TAILSCALE_SERVE_TIMEOUT_SECONDS
if ! configure_tailscale_serve --bg https+insecure://localhost:8006 >/dev/null 2>&1; then
    pass "An invalid Serve timeout is rejected"
else
    fail "An invalid Serve timeout is rejected"
fi

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
