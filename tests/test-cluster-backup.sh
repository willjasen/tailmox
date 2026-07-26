#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_DIR/log"
export TAILMOX_CLUSTER_BACKUP_DIR="$TEST_DIR/backups"
export TAILMOX_EXISTING_CLUSTER_BACKUP_DIR="$TEST_DIR/backups"
export TAILMOX_PVE_CONFIG_DIR="$TEST_DIR/etc/pve"
export TAILMOX_COROSYNC_CONFIG_DIR="$TEST_DIR/etc/corosync"
export TAILMOX_HOSTS_FILE="$TEST_DIR/etc/hosts"

mkdir -p "$TAILMOX_PVE_CONFIG_DIR/nodes/pve1" "$TAILMOX_COROSYNC_CONFIG_DIR"
printf '%s\n' 'storage: local-zfs' > "$TAILMOX_PVE_CONFIG_DIR/storage.cfg"
printf '%s\n' 'node {' > "$TAILMOX_COROSYNC_CONFIG_DIR/corosync.conf"
printf '%s\n' '127.0.0.1 localhost' > "$TAILMOX_HOSTS_FILE"

source "$TEST_ROOT/tailmox.sh"

PASS_COUNT=0
FAIL_COUNT=0
PVECM_CALL_COUNT=0

function check_all_peers_online() {
    return 0
}

function tailscale() {
    if [[ "${1:-}" == "ip" && "${2:-}" == "-4" ]]; then
        printf '%s\n' '100.64.0.1'
        return 0
    fi

    return 2
}

function pvecm() {
    PVECM_CALL_COUNT=$((PVECM_CALL_COUNT + 1))

    return 0
}

function pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

function fail() {
    printf 'FAIL: %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

if backup_proxmox_cluster_configuration >/dev/null 2>&1; then
    archive_count=$(find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f -name '*.tar.gz' | wc -l | tr -d ' ')
    archive_path=$(find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f -name '*.tar.gz' | head -1)
    archive_listing=$(tar -tzf "$archive_path")
    archive_mode=$(stat -f '%Lp' "$archive_path" 2>/dev/null || stat -c '%a' "$archive_path")

    if [[ "$archive_count" -eq 1 ]] &&
        [[ "$archive_listing" == *"${TAILMOX_PVE_CONFIG_DIR#/}/storage.cfg"* ]] &&
        [[ "$archive_listing" == *"${TAILMOX_COROSYNC_CONFIG_DIR#/}/corosync.conf"* ]] &&
        [[ "$archive_listing" == *"${TAILMOX_HOSTS_FILE#/}"* ]] &&
        [[ "$archive_mode" == "600" ]]; then
        pass "cluster configuration is archived with private permissions"
    else
        fail "cluster configuration is archived with private permissions"
    fi
else
    fail "cluster configuration is archived with private permissions"
fi

if backup_proxmox_cluster_configuration >/dev/null 2>&1 &&
    [[ $(find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f -name '*.tar.gz' | wc -l | tr -d ' ') -eq 2 ]]; then
    pass "multiple cluster changes keep distinct archives"
else
    fail "multiple cluster changes keep distinct archives"
fi

rm -rf "$TAILMOX_CLUSTER_BACKUP_DIR"
PVECM_CALL_COUNT=0
if create_cluster >/dev/null 2>&1 &&
    [[ "$PVECM_CALL_COUNT" -eq 1 ]] &&
    find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f -name '*.tar.gz' | grep -q .; then
    pass "cluster creation archives configuration before pvecm"
else
    fail "cluster creation archives configuration before pvecm"
fi

rm -rf "$TAILMOX_PVE_CONFIG_DIR" "$TAILMOX_CLUSTER_BACKUP_DIR"
PVECM_CALL_COUNT=0
if create_cluster >/dev/null 2>&1; then
    fail "missing Proxmox configuration blocks cluster creation"
elif [[ "$PVECM_CALL_COUNT" -ne 0 ]]; then
    fail "missing Proxmox configuration blocks cluster creation"
else
    pass "missing Proxmox configuration blocks cluster creation"
fi

mkdir -p "$TAILMOX_PVE_CONFIG_DIR"
printf '%s\n' 'storage: local-zfs' > "$TAILMOX_PVE_CONFIG_DIR/storage.cfg"
printf '%s\n' 'not a directory' > "$TAILMOX_CLUSTER_BACKUP_DIR"
PVECM_CALL_COUNT=0
if create_cluster >/dev/null 2>&1; then
    fail "backup failure blocks cluster creation"
elif [[ "$PVECM_CALL_COUNT" -ne 0 ]]; then
    fail "backup failure blocks cluster creation"
else
    pass "backup failure blocks cluster creation"
fi
printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
