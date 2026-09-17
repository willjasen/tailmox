#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"
export TAILMOX_AUTH_ENV_FILE="$TEST_LOG_DIR/tailscale.env"
export TAILMOX_AUTH_PROMPT_INPUT="$TEST_LOG_DIR/prompt-input"
export TAILMOX_AUTH_PROMPT_OUTPUT="$TEST_LOG_DIR/prompt-output"

source "$TEST_ROOT/tailmox.sh"

CONNECTED_STATUS='{
  "BackendState": "Running",
  "Self": {
    "Online": true,
    "DNSName": "pve1.example.ts.net.",
    "Tags": ["tag:server", "tag:tailmox"]
  }
}'
MISSING_TAG_STATUS='{
  "BackendState": "Running",
  "Self": {
    "Online": true,
    "DNSName": "pve1.example.ts.net.",
    "Tags": ["tag:server"]
  }
}'
CONNECTED_OFFLINE_STATUS='{
  "BackendState": "Running",
  "Self": {
    "Online": false,
    "DNSName": "pve1.example.ts.net.",
    "Tags": ["tag:tailmox"]
  }
}'
LOGGED_OUT_STATUS='{"BackendState": "NeedsLogin", "Self": null}'
MALFORMED_STATUS='{"BackendState": "Running", "Self":'

MOCK_STATUS="$CONNECTED_STATUS"
MOCK_STATUS_AFTER_UP="$CONNECTED_STATUS"
TAILSCALE_UP_CALLS=""
MOCK_STATUS_FAILURE=false

function tailscale() {
    if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
        if [[ "$MOCK_STATUS_FAILURE" == "true" ]]; then
            return 1
        fi
        printf '%s\n' "$MOCK_STATUS"
        return 0
    fi

    if [[ "${1:-}" == "up" ]]; then
        TAILSCALE_UP_CALLS="${*}"
        MOCK_STATUS="$MOCK_STATUS_AFTER_UP"
        return 0
    fi

    if [[ "${1:-}" == "ip" && "${2:-}" == "-4" ]]; then
        printf '%s\n' "100.64.0.1"
        return 0
    fi

    return 2
}

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

MOCK_STATUS="$CONNECTED_STATUS"
TAILSCALE_UP_CALLS=""
if start_tailscale "" >/dev/null 2>&1 && [[ -z "$TAILSCALE_UP_CALLS" ]]; then
    pass "connected tagged device preserves its existing Tailscale login"
else
    fail "connected tagged device preserves its existing Tailscale login"
fi

MOCK_STATUS="$CONNECTED_OFFLINE_STATUS"
TAILSCALE_UP_CALLS=""
if start_tailscale "" >/dev/null 2>&1 && [[ -z "$TAILSCALE_UP_CALLS" ]]; then
    pass "temporarily offline connected device is not logged in again"
else
    fail "temporarily offline connected device is not logged in again"
fi

MOCK_STATUS="$MISSING_TAG_STATUS"
TAILSCALE_UP_CALLS=""
if ! start_tailscale "" >/dev/null 2>&1 && [[ -z "$TAILSCALE_UP_CALLS" ]]; then
    pass "connected device without tag:tailmox fails without logging in again"
else
    fail "connected device without tag:tailmox fails without logging in again"
fi

MOCK_STATUS="$LOGGED_OUT_STATUS"
MOCK_STATUS_AFTER_UP="$CONNECTED_STATUS"
TAILSCALE_UP_CALLS=""
rm -f "$TAILMOX_AUTH_ENV_FILE"
if start_tailscale "tskey-test" >/dev/null 2>&1 &&
    [[ "$TAILSCALE_UP_CALLS" == "up --auth-key=tskey-test" ]] &&
    [[ "$(cat "$TAILMOX_AUTH_ENV_FILE")" == "TAILMOX_AUTH_KEY=tskey-test" ]] &&
    [[ "$(stat -c '%a' "$TAILMOX_AUTH_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$TAILMOX_AUTH_ENV_FILE")" == "600" ]]; then
    pass "logged-out device uses and securely saves the supplied auth key"
else
    fail "logged-out device uses and securely saves the supplied auth key"
fi

MOCK_STATUS="$LOGGED_OUT_STATUS"
MOCK_STATUS_AFTER_UP="$CONNECTED_STATUS"
TAILSCALE_UP_CALLS=""
if start_tailscale "" >/dev/null 2>&1 &&
    [[ "$TAILSCALE_UP_CALLS" == "up --auth-key=tskey-test" ]]; then
    pass "logged-out device reuses the saved auth key without interactive login"
else
    fail "logged-out device reuses the saved auth key without interactive login"
fi

chmod 0644 "$TAILMOX_AUTH_ENV_FILE"
if ! load_saved_tailscale_auth_key >/dev/null 2>&1; then
    pass "saved auth key is rejected when its file permissions are not private"
else
    fail "saved auth key is rejected when its file permissions are not private"
fi
chmod 0600 "$TAILMOX_AUTH_ENV_FILE"

MOCK_STATUS="$LOGGED_OUT_STATUS"
MOCK_STATUS_AFTER_UP="$CONNECTED_STATUS"
TAILSCALE_UP_CALLS=""
rm -f "$TAILMOX_AUTH_ENV_FILE"
printf '%s\n' 'tskey-prompted' > "$TAILMOX_AUTH_PROMPT_INPUT"
touch "$TAILMOX_AUTH_PROMPT_OUTPUT"
if start_tailscale "" >/dev/null 2>&1 &&
    [[ "$TAILSCALE_UP_CALLS" == "up --auth-key=tskey-prompted" ]] &&
    [[ "$(cat "$TAILMOX_AUTH_ENV_FILE")" == "TAILMOX_AUTH_KEY=tskey-prompted" ]]; then
    pass "logged-out device securely prompts for and saves an auth key"
else
    fail "logged-out device securely prompts for and saves an auth key"
fi

MOCK_STATUS="$LOGGED_OUT_STATUS"
TAILSCALE_UP_CALLS=""
rm -f "$TAILMOX_AUTH_ENV_FILE" "$TAILMOX_AUTH_PROMPT_INPUT"
if ! start_tailscale "" >/dev/null 2>&1 && [[ -z "$TAILSCALE_UP_CALLS" ]]; then
    pass "logged-out device never falls back to an interactive Tailscale login link"
else
    fail "logged-out device never falls back to an interactive Tailscale login link"
fi

MOCK_STATUS="$LOGGED_OUT_STATUS"
MOCK_STATUS_AFTER_UP="$MISSING_TAG_STATUS"
TAILSCALE_UP_CALLS=""
rm -f "$TAILMOX_AUTH_ENV_FILE"
if ! start_tailscale "tskey-test" >/dev/null 2>&1 &&
    [[ "$TAILSCALE_UP_CALLS" == "up --auth-key=tskey-test" ]]; then
    pass "auth key must result in a device carrying tag:tailmox"
else
    fail "auth key must result in a device carrying tag:tailmox"
fi

MOCK_STATUS="$MALFORMED_STATUS"
TAILSCALE_UP_CALLS=""
if ! verify_local_tailmox_tag >/dev/null 2>&1; then
    pass "malformed post-connection status fails the local tag check"
else
    fail "malformed post-connection status fails the local tag check"
fi

MOCK_STATUS_FAILURE=true
TAILSCALE_UP_CALLS=""
if ! start_tailscale "tskey-test" >/dev/null 2>&1 && [[ -z "$TAILSCALE_UP_CALLS" ]]; then
    pass "status command failure refuses to change Tailscale connectivity"
else
    fail "status command failure refuses to change Tailscale connectivity"
fi
if ! verify_local_tailmox_tag >/dev/null 2>&1; then
    pass "post-connection status command failure fails the local tag check"
else
    fail "post-connection status command failure fails the local tag check"
fi
MOCK_STATUS_FAILURE=false

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
