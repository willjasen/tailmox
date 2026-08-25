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

printf '%s\n' '{
  "schemaVersion": 1,
  "cluster": {"name": "production"},
  "members": [
    {"name": "pve1", "tailscaleIPv4": "100.64.0.1", "status": "active"},
    {"name": "pve2", "tailscaleIPv4": "100.64.0.2", "status": "active",
     "date_joined": "2026-07-30T20:05:00Z"}
  ]
}' > "$STATE_FILE"

HOSTNAME=pve1
state_before=$(cksum "$STATE_FILE")
info_output=$(show_info)
state_after=$(cksum "$STATE_FILE")
if [[ "$info_output" == *"Tailmox cluster: production"* ]] &&
    [[ "$info_output" == *"pve1 (100.64.0.1) — active"* ]] &&
    [[ "$info_output" == *"pve2 (100.64.0.2) — active — joined 2026-07-30T20:05:00Z"* ]] &&
    [[ "$state_before" == "$state_after" ]]; then
    pass "info reads members-based shared state without modifying it"
else
    fail "info reads members-based shared state without modifying it"
fi

HOSTNAME=pve3
if [[ "$(show_info)" == "This host is not part of a Tailmox cluster." ]]; then
    pass "info rejects a host absent from shared cluster state"
else
    fail "info rejects a host absent from shared cluster state"
fi

PVE_NODES_OUTPUT='    Nodeid      Votes Name
         1          1 pve1 (local)
         2          1 pve2'
PVE_DELETED_NODE=''
function pvecm() {
    case "$1" in
        status) printf '%s\n' 'Cluster information' ;;
        nodes) printf '%s\n' "$PVE_NODES_OUTPUT" ;;
        delnode) PVE_DELETED_NODE="$2" ;;
    esac
}
export TAILMOX_ASSUME_YES=true
HOSTNAME=pve1
if remove_cluster_node pve2 >/dev/null 2>&1 &&
    [[ "$PVE_DELETED_NODE" == pve2 ]] &&
    ! jq -e '.hosts[] | select(.hostname == "pve2")' "$STATE_FILE" >/dev/null 2>&1; then
    pass "remove deletes a remote Proxmox node and Tailmox membership record"
else
    fail "remove deletes a remote Proxmox node and Tailmox membership record"
fi

if ! remove_cluster_node pve1 >/dev/null 2>&1 && [[ -z "$PVE_DELETED_NODE" || "$PVE_DELETED_NODE" == pve2 ]]; then
    pass "remove refuses to delete the local node"
else
    fail "remove refuses to delete the local node"
fi
unset TAILMOX_ASSUME_YES

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
