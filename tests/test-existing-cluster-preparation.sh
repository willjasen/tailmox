#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_WORK_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_WORK_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_WORK_DIR/log"
export TAILMOX_CLUSTER_BACKUP_DIR="$TEST_WORK_DIR/backups"
export TAILMOX_PVE_CONFIG_DIR="$TEST_WORK_DIR/etc/pve"
export TAILMOX_COROSYNC_CONFIG_DIR="$TEST_WORK_DIR/etc/corosync"
export TAILMOX_HOSTS_FILE="$TEST_WORK_DIR/etc/hosts"
export TAILMOX_COROSYNC_CONFIG="$TAILMOX_PVE_CONFIG_DIR/corosync.conf"
export TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE="$TEST_WORK_DIR/confirmation"

mkdir -p "$TAILMOX_PVE_CONFIG_DIR" "$TAILMOX_COROSYNC_CONFIG_DIR"
printf '%s\n' '127.0.0.1 localhost' > "$TAILMOX_HOSTS_FILE"

source "$TEST_ROOT/tailmox.sh"

PASS_COUNT=0
FAIL_COUNT=0
MOCK_CLUSTER_STATUS=""
MOCK_ALL_PEERS_ONLINE=true
MOCK_COROSYNC_VALID=true
COROSYNC_CALL_COUNT=0

function pvecm() {
    if [[ "${1:-}" == "status" ]]; then
        printf '%s\n' "$MOCK_CLUSTER_STATUS"
        return 0
    fi
    return 2
}

function tailscale() {
    [[ "${1:-}" == "ping" ]]
}

function check_all_peers_online() {
    [[ "$MOCK_ALL_PEERS_ONLINE" == "true" ]]
}

function corosync() {
    COROSYNC_CALL_COUNT=$((COROSYNC_CALL_COUNT + 1))
    [[ "$*" == "-t -c ${TAILMOX_COROSYNC_CONFIG}.new" ]] &&
        [[ "$MOCK_COROSYNC_VALID" == "true" ]]
}

function pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

function fail() {
    printf 'FAIL: %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

function write_config() {
    local first_address=$1
    local second_address=$2

    printf '%s\n' \
        'nodelist {' \
        '  node {' \
        '    name: pve1' \
        '    nodeid: 1' \
        "    ring0_addr: $first_address" \
        '  }' \
        '  node {' \
        '    name: pve2' \
        '    nodeid: 2' \
        "    ring0_addr: $second_address" \
        '  }' \
        '}' \
        'totem {' \
        '  cluster_name: production' \
        '  config_version: 7' \
        '  interface {' \
        '    linknumber: 0' \
        '  }' \
        '}' > "$TAILMOX_COROSYNC_CONFIG"
}

MOCK_CLUSTER_STATUS='Cluster information
-------------------
Name:             production
Quorate:          Yes
Membership information
----------------------
         1          1 100.64.0.1 (local)
         2          1 100.64.0.2'

ALL_PEERS='[
  {"hostname":"pve1","ip":"100.64.0.1","online":true},
  {"hostname":"pve2","ip":"100.64.0.2","online":true}
]'

write_config "100.64.0.1" "100.64.0.2"
if prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    jq -e '
        .schemaVersion == 1 and .cluster.name == "production"
        and (.members == [
            {name: "pve1", tailscaleIPv4: "100.64.0.1", status: "active"},
            {name: "pve2", tailscaleIPv4: "100.64.0.2", status: "active"}
        ])
    ' "$TAILMOX_PVE_CONFIG_DIR/tailmox/state.json" >/dev/null &&
    grep -q 'config_version: 7' "$TAILMOX_COROSYNC_CONFIG"; then
    pass "already prepared cluster records verified shared Tailmox state"
else
    fail "already prepared cluster records verified shared Tailmox state"
fi

write_config "192.0.2.1" "192.0.2.2"
printf '%s\n' 'MIGRATE' > "$TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE"
COROSYNC_CALL_COUNT=0
if prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'ring0_addr: 100.64.0.1' "$TAILMOX_COROSYNC_CONFIG" &&
    grep -q 'ring0_addr: 100.64.0.2' "$TAILMOX_COROSYNC_CONFIG" &&
    jq -e 'all(.members[]; .status == "active")' "$TAILMOX_PVE_CONFIG_DIR/tailmox/state.json" >/dev/null &&
    grep -q 'config_version: 8' "$TAILMOX_COROSYNC_CONFIG" &&
    [[ "$COROSYNC_CALL_COUNT" -eq 1 ]] &&
    [[ -n "$(find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f -name '*.tar.gz' -print -quit)" ]]; then
    pass "confirmed migration validates and updates every member with a backup"
else
    fail "confirmed migration validates and updates every member with a backup"
fi

if write_tailmox_cluster_state "$MOCK_CLUSTER_STATUS" $'pve1\t192.0.2.1\npve2\t192.0.2.2' pending >/dev/null 2>&1 &&
    jq -e '(.members | length) == 2 and all(.members[]; .status == "pending")' "$TAILMOX_PVE_CONFIG_DIR/tailmox/state.json" >/dev/null; then
    pass "pending state records every existing member"
else
    fail "pending state records every existing member"
fi

write_config "192.0.2.1" "192.0.2.2"
MOCK_COROSYNC_VALID=false
printf '%s\n' 'MIGRATE' > "$TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE"
if ! prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'ring0_addr: 192.0.2.1' "$TAILMOX_COROSYNC_CONFIG" &&
    grep -q 'config_version: 7' "$TAILMOX_COROSYNC_CONFIG" &&
    [[ ! -e "${TAILMOX_COROSYNC_CONFIG}.new" ]]; then
    pass "Corosync validation failure leaves shared configuration unchanged"
else
    fail "Corosync validation failure leaves shared configuration unchanged"
fi
MOCK_COROSYNC_VALID=true

write_config "192.0.2.1" "192.0.2.2"
printf '%s\n' 'NO' > "$TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE"
if ! prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'ring0_addr: 192.0.2.1' "$TAILMOX_COROSYNC_CONFIG"; then
    pass "migration requires an exact explicit confirmation"
else
    fail "migration requires an exact explicit confirmation"
fi

write_config "192.0.2.1" "192.0.2.2"
ALL_PEERS='[
  {"hostname":"pve1","ip":"100.64.0.1","online":true}
]'
printf '%s\n' 'MIGRATE' > "$TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE"
if ! prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'ring0_addr: 192.0.2.2' "$TAILMOX_COROSYNC_CONFIG"; then
    pass "missing existing member blocks a partial network migration"
else
    fail "missing existing member blocks a partial network migration"
fi

write_config "192.0.2.1" "192.0.2.2"
printf '%s\n' 'administrator pending edit' > "${TAILMOX_COROSYNC_CONFIG}.new"
ALL_PEERS='[
  {"hostname":"pve1","ip":"100.64.0.1","online":true},
  {"hostname":"pve2","ip":"100.64.0.2","online":true}
]'
printf '%s\n' 'MIGRATE' > "$TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE"
if ! prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'administrator pending edit' "${TAILMOX_COROSYNC_CONFIG}.new" &&
    grep -q 'ring0_addr: 192.0.2.1' "$TAILMOX_COROSYNC_CONFIG"; then
    pass "pending administrator Corosync edit is not overwritten"
else
    fail "pending administrator Corosync edit is not overwritten"
fi
rm -f "${TAILMOX_COROSYNC_CONFIG}.new"

write_config "192.0.2.1" "192.0.2.2"
MOCK_ALL_PEERS_ONLINE=false
printf '%s\n' 'MIGRATE' > "$TAILMOX_EXISTING_CLUSTER_CONFIRMATION_DEVICE"
if ! prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'ring0_addr: 192.0.2.1' "$TAILMOX_COROSYNC_CONFIG"; then
    pass "peer going offline during confirmation blocks migration"
else
    fail "peer going offline during confirmation blocks migration"
fi
MOCK_ALL_PEERS_ONLINE=true

ALL_PEERS='[
  {"hostname":"pve1","ip":"100.64.0.1","online":true},
  {"hostname":"pve2","ip":"100.64.0.2","online":true}
]'
MOCK_CLUSTER_STATUS='Cluster information
-------------------
Name:             production
Quorate:          No'
write_config "192.0.2.1" "192.0.2.2"
if ! prepare_existing_cluster_for_tailmox >/dev/null 2>&1 &&
    grep -q 'ring0_addr: 192.0.2.1' "$TAILMOX_COROSYNC_CONFIG"; then
    pass "non-quorate cluster fails closed"
else
    fail "non-quorate cluster fails closed"
fi

MOCK_CLUSTER_STATUS='Cluster information
-------------------
Name:             production
Quorate:          Yes'
ALL_PEERS='[
  {"hostname":"pve1","ip":"100.64.0.1","online":true},
  {"hostname":"pve2","ip":"100.64.0.2","online":true}
]'
REMOTE_CLUSTER_STATUS_JSON='{"data":[
  {"type":"cluster","name":"production"},
  {"type":"node","name":"pve1","ip":"100.64.0.1"},
  {"type":"node","name":"pve2","ip":"100.64.0.2"}
]}'
REMOTE_CLUSTER_JOIN_JSON='{"data":{"nodelist":[
  {"name":"pve1","ring0_addr":"100.64.0.1"},
  {"name":"pve2","ring0_addr":"100.64.0.2"}
]}}'
if remote_cluster_is_ready_for_tailmox_join >/dev/null 2>&1; then
    pass "new host accepts a fully prepared remote cluster"
else
    fail "new host accepts a fully prepared remote cluster"
fi

REMOTE_CLUSTER_STATUS_JSON='{"data":[
  {"type":"cluster","name":"production"},
  {"type":"node","name":"pve1","ip":"100.64.0.1"},
  {"type":"node","name":"pve2","ip":"192.0.2.2"}
]}'
REMOTE_CLUSTER_JOIN_JSON='{"data":{"nodelist":[
  {"name":"pve1","ring0_addr":"100.64.0.1"},
  {"name":"pve2","ring0_addr":"192.0.2.2"}
]}}'
if ! remote_cluster_is_ready_for_tailmox_join >/dev/null 2>&1; then
    pass "new host rejects a partially prepared remote cluster"
else
    fail "new host rejects a partially prepared remote cluster"
fi

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
