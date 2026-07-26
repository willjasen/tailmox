#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export TAILMOX_BIN_DIR="$TEST_DIR/bin"
export TAILMOX_LOG_DIR="$TEST_DIR/log"
export TAILMOX_CLUSTER_BACKUP_DIR="$TEST_DIR/backups"
export TAILMOX_EXISTING_CLUSTER_BACKUP_DIR="$TEST_DIR/backups"
export TAILMOX_PVE_CONFIG_DIR="$TEST_DIR/etc/pve"
export TAILMOX_COROSYNC_CONFIG_DIR="$TEST_DIR/etc/corosync"
export TAILMOX_HOSTS_FILE="$TEST_DIR/etc/hosts"
export TAILMOX_WEB_ROOT="$TEST_DIR/web-root-not-installed"

mkdir -p "$TAILMOX_PVE_CONFIG_DIR" "$TAILMOX_COROSYNC_CONFIG_DIR"
printf '%s\n' 'storage: local-zfs' > "$TAILMOX_PVE_CONFIG_DIR/storage.cfg"
printf '%s\n' 'totem {' > "$TAILMOX_COROSYNC_CONFIG_DIR/corosync.conf"
printf '%s\n' '127.0.0.1 localhost' > "$TAILMOX_HOSTS_FILE"

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

if empty_output=$("$TEST_ROOT/tailmox" backups 2>&1) &&
    [[ "$empty_output" == "No Tailmox configuration backups found." ]] &&
    [[ ! -e "$TAILMOX_LOG_DIR/tailmox.log" ]]; then
    pass "backup listing is read-only and reports an empty inventory"
else
    fail "backup listing is read-only and reports an empty inventory"
fi

if create_output=$("$TEST_ROOT/tailmox" backups create 2>&1) &&
    [[ "$create_output" == *"Archived the current Proxmox cluster configuration at"* ]] &&
    [[ $(find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f -name 'proxmox-cluster-*.tar.gz' | wc -l | tr -d ' ') -eq 1 ]]; then
    pass "backup create makes a configuration archive"
else
    fail "backup create makes a configuration archive"
fi

if list_output=$("$TEST_ROOT/tailmox" backups list 2>&1) &&
    [[ "$list_output" == *"TYPE"* ]] &&
    [[ "$list_output" == *"cluster"* ]] &&
    [[ "$list_output" == *"valid"* ]] &&
    [[ "$list_output" == *"$TAILMOX_CLUSTER_BACKUP_DIR/proxmox-cluster-"* ]]; then
    pass "backup listing reports created archives"
else
    fail "backup listing reports created archives"
fi

if "$TEST_ROOT/tailmox" backups remove >/dev/null 2>&1; then
    fail "unknown backup actions are rejected"
else
    pass "unknown backup actions are rejected"
fi

rm -rf "$TAILMOX_PVE_CONFIG_DIR" "$TAILMOX_CLUSTER_BACKUP_DIR"
if "$TEST_ROOT/tailmox" backups create >/dev/null 2>&1; then
    fail "backup creation fails closed without Proxmox configuration"
elif [[ -d "$TAILMOX_CLUSTER_BACKUP_DIR" ]] &&
    find "$TAILMOX_CLUSTER_BACKUP_DIR" -type f | grep -q .; then
    fail "backup creation fails closed without Proxmox configuration"
else
    pass "backup creation fails closed without Proxmox configuration"
fi

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
fi
