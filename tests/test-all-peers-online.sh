#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"
export TAILMOX_CLUSTER_BACKUP_DIR="$TEST_LOG_DIR/backups"
export TAILMOX_PVE_CONFIG_DIR="$TEST_LOG_DIR/etc/pve"
export TAILMOX_COROSYNC_CONFIG_DIR="$TEST_LOG_DIR/etc/corosync"
export TAILMOX_HOSTS_FILE="$TEST_LOG_DIR/etc/hosts"

mkdir -p "$TAILMOX_PVE_CONFIG_DIR" "$TAILMOX_COROSYNC_CONFIG_DIR"
printf '%s\n' 'mock pve configuration' > "$TAILMOX_PVE_CONFIG_DIR/storage.cfg"
printf '%s\n' 'mock corosync configuration' > "$TAILMOX_COROSYNC_CONFIG_DIR/corosync.conf"
printf '%s\n' '127.0.0.1 localhost' > "$TAILMOX_HOSTS_FILE"

source "$TEST_ROOT/tailmox.sh"

MOCK_TAILSCALE_STATUS=""
MOCK_TAILSCALE_EXIT=0
PVECM_CALL_COUNT=0

function tailscale() {
    if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
        printf '%s\n' "$MOCK_TAILSCALE_STATUS"
        return "$MOCK_TAILSCALE_EXIT"
    fi

    if [[ "${1:-}" == "ip" && "${2:-}" == "-4" ]]; then
        printf '%s\n' "100.64.0.1"
        return 0
    fi

    return 2
}

function pvecm() {
    PVECM_CALL_COUNT=$((PVECM_CALL_COUNT + 1))
    return 0
}

PASS_COUNT=0
FAIL_COUNT=0

function run_case() {
    local name=$1
    local expected=$2
    local actual

    if check_all_peers_online >/dev/null 2>&1; then
        actual=0
    else
        actual=$?
    fi

    if [[ "$actual" -eq "$expected" ]]; then
        printf 'PASS: %s\n' "$name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

MOCK_TAILSCALE_EXIT=0
MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {
    "node-1": {"HostName": "pve1", "Tags": ["tag:tailmox"], "Online": true},
    "node-2": {"HostName": "pve2", "Tags": ["tag:tailmox"], "Online": true}
  }
}'
run_case "all Tailmox peers online" 0

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {
    "node-1": {"HostName": "pve1", "Tags": ["tag:tailmox"], "Online": true},
    "node-2": {"HostName": "pve2", "Tags": ["tag:tailmox"], "Online": false}
  }
}'
run_case "one Tailmox peer offline fails closed" 1

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {
    "node-1": {"HostName": "pve1", "Tags": ["tag:tailmox"], "Online": true},
    "node-2": {"HostName": "lab1", "Tags": ["tag:tailmox-test"], "Online": false}
  }
}'
run_case "similarly named tag is not included" 0

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {}
}'
run_case "no existing Tailmox peers allows bootstrap" 0

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {"node-1": {"Tags": ["tag:tailmox"], "Online": true}}
}'
run_case "incomplete peer data fails closed" 1

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true}
}'
run_case "missing peer object fails closed" 1

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Stopped",
  "Self": {"Online": false},
  "Peer": {}
}'
run_case "local Tailscale not online fails closed" 1

MOCK_TAILSCALE_STATUS='not-json'
run_case "malformed status fails closed" 1

MOCK_TAILSCALE_EXIT=1
MOCK_TAILSCALE_STATUS=''
run_case "tailscale status failure fails closed" 1

MOCK_TAILSCALE_EXIT=0
MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {
    "node-1": {"HostName": "pve1", "Tags": ["tag:tailmox"], "Online": true},
    "node-2": {"HostName": "pve2", "Tags": ["tag:tailmox"], "Online": false}
  }
}'
PVECM_CALL_COUNT=0
if create_cluster >/dev/null 2>&1; then
    printf 'FAIL: offline peer blocks pvecm create (create_cluster succeeded)\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
elif [[ "$PVECM_CALL_COUNT" -ne 0 ]]; then
    printf 'FAIL: offline peer blocks pvecm create (pvecm was called)\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf 'PASS: offline peer blocks pvecm create\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi

MOCK_TAILSCALE_STATUS='{
  "BackendState": "Running",
  "Self": {"Online": true},
  "Peer": {
    "node-1": {"HostName": "pve1", "Tags": ["tag:tailmox"], "Online": true},
    "node-2": {"HostName": "pve2", "Tags": ["tag:tailmox"], "Online": true}
  }
}'
PVECM_CALL_COUNT=0
if create_cluster >/dev/null 2>&1 && [[ "$PVECM_CALL_COUNT" -eq 1 ]]; then
    printf 'PASS: all-online gate permits pvecm create\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: all-online gate permits pvecm create\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
