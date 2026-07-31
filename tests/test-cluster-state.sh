#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_WORK_DIR/log"
export TAILMOX_PVE_CONFIG_DIR="$TEST_WORK_DIR/etc/pve"

source "$TEST_ROOT/tailmox.sh"

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

if [[ "$STATE_FILE" == "$TAILMOX_PVE_CONFIG_DIR/tailmox/state.json" ]]; then
    pass "cluster state defaults to the shared Proxmox filesystem"
else
    fail "cluster state defaults to the shared Proxmox filesystem"
fi

write_state "pve-c0" "100.64.0.10" "pve-c0.example.ts.net" \
    "2026-07-30T20:00:00Z"
write_state "pve-c1" "100.64.0.11" "pve-c1.example.ts.net" \
    "2026-07-30T20:05:00Z"

if jq -e '
    (.hosts | length) == 2 and
    .hosts[0] == {
        hostname: "pve-c0",
        ip: "100.64.0.10",
        dnsName: "pve-c0.example.ts.net",
        date_joined: "2026-07-30T20:00:00Z"
    } and
    .hosts[1] == {
        hostname: "pve-c1",
        ip: "100.64.0.11",
        dnsName: "pve-c1.example.ts.net",
        date_joined: "2026-07-30T20:05:00Z"
    }
' "$STATE_FILE" >/dev/null; then
    pass "a joining pve-c1 entry is appended to existing shared state"
else
    fail "a joining pve-c1 entry is appended to existing shared state"
fi

write_state "pve-c1" "100.64.0.21" "pve-c1.changed.ts.net" \
    "2026-07-30T21:00:00Z"

if jq -e '
    (.hosts | length) == 2 and
    (.hosts[] | select(.hostname == "pve-c1")) == {
        hostname: "pve-c1",
        ip: "100.64.0.21",
        dnsName: "pve-c1.changed.ts.net",
        date_joined: "2026-07-30T20:05:00Z"
    }
' "$STATE_FILE" >/dev/null; then
    pass "updating an existing host preserves its original join time"
else
    fail "updating an existing host preserves its original join time"
fi

printf '%s\n' '{malformed state' > "$STATE_FILE"
if ! write_state "pve-c2" "100.64.0.12" "pve-c2.example.ts.net" \
        "2026-07-30T21:05:00Z" &&
    grep -Fqx '{malformed state' "$STATE_FILE"; then
    pass "malformed shared state is rejected without being overwritten"
else
    fail "malformed shared state is rejected without being overwritten"
fi

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    printf '%d cluster-state test(s) failed.\n' "$FAIL_COUNT" >&2
    exit 1
fi

printf 'All %d cluster-state tests passed.\n' "$PASS_COUNT"
