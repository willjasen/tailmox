#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"
export TAILMOX_SYSTEMD_DIR="$TEST_LOG_DIR/systemd"
export TAILMOX_WEB_ROOT="$TEST_LOG_DIR/web"
export TAILMOX_CLUSTER_BACKUP_DIR="$TEST_LOG_DIR/backups"
export TAILMOX_EXISTING_CLUSTER_BACKUP_DIR="$TEST_LOG_DIR/backups"
mkdir -p "$TAILMOX_SYSTEMD_DIR" "$TAILMOX_CLUSTER_BACKUP_DIR" "$TEST_LOG_DIR/config"
printf '%s\n' 'nodes: pve1' > "$TEST_LOG_DIR/config/cluster.conf"
tar -czf \
    "$TAILMOX_CLUSTER_BACKUP_DIR/proxmox-cluster-20260726T120000Z-101.tar.gz" \
    -C "$TEST_LOG_DIR/config" cluster.conf
printf '%s\n' 'nodelist { node { name: pve1 } }' \
    > "$TAILMOX_CLUSTER_BACKUP_DIR/corosync-20260726T130000Z-102.conf"

source "$TEST_ROOT/tailmox.sh"

SYSTEMCTL_CALLS="$TEST_LOG_DIR/systemctl-calls"
TAILSCALE_CALLS="$TEST_LOG_DIR/tailscale-calls"

function systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
}

function tailscale() {
    printf '%s\n' "$*" >> "$TAILSCALE_CALLS"

    if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
        printf '%s\n' '{"Self":{"DNSName":"prox1.risk-mermaid.ts.net."}}'
    fi
}

OUTPUT=$(start_web_terminal)
EXPECTED_OUTPUT=$'Tailmox web server started.\nhttps://prox1.risk-mermaid.ts.net:8669/'

if [[ "$OUTPUT" != "$EXPECTED_OUTPUT" ]]; then
    printf 'FAIL: launcher output did not contain only the status and service URL\n'
    printf 'Actual output:\n%s\n' "$OUTPUT"
    exit 1
fi

if [[ ! -f "$TAILMOX_SYSTEMD_DIR/tailmox-web.service" ]]; then
    printf 'FAIL: systemd service was not installed\n'
    exit 1
fi

if ! grep -Fq -- '--base-path /terminal' "$TAILMOX_SYSTEMD_DIR/tailmox-web.service"; then
    printf 'FAIL: ttyd was not configured for the dashboard terminal path\n'
    exit 1
fi

if ! grep -Fxq 'enable tailmox-web.service' "$SYSTEMCTL_CALLS" ||
    ! grep -Fxq 'restart tailmox-web.service' "$SYSTEMCTL_CALLS"; then
    printf 'FAIL: systemd service was not enabled and restarted\n'
    exit 1
fi

if ! grep -Fxq \
    "serve --bg --yes --https=8669 --set-path=/ $TAILMOX_WEB_ROOT" \
    "$TAILSCALE_CALLS"; then
    printf 'FAIL: dashboard was not exposed through the host Tailscale name\n'
    exit 1
fi

if ! grep -Fxq \
    'serve --bg --yes --https=8669 --set-path=/terminal http://127.0.0.1:8670' \
    "$TAILSCALE_CALLS"; then
    printf 'FAIL: web terminal was not mounted beneath the dashboard\n'
    exit 1
fi

for asset in index.html tailmox.css tailmox.js backups.json; do
    if [[ ! -f "$TAILMOX_WEB_ROOT/$asset" ]]; then
        printf 'FAIL: dashboard asset %s was not installed\n' "$asset"
        exit 1
    fi
done

if ! jq -e '
    .backups | length == 2
    and .[0].filename == "corosync-20260726T130000Z-102.conf"
    and .[0].type == "corosync"
    and .[0].integrity == "valid"
    and .[1].filename == "proxmox-cluster-20260726T120000Z-101.tar.gz"
    and .[1].type == "cluster"
    and .[1].integrity == "valid"
' "$TAILMOX_WEB_ROOT/backups.json" >/dev/null; then
    printf 'FAIL: dashboard backup inventory was incomplete or incorrectly ordered\n'
    exit 1
fi

if grep -Fq "$TEST_LOG_DIR" "$TAILMOX_WEB_ROOT/backups.json"; then
    printf 'FAIL: dashboard backup inventory exposed an absolute host path\n'
    exit 1
fi

printf '%s' '' > "$TAILMOX_CLUSTER_BACKUP_DIR/corosync-20260726T140000Z-103.conf"
if ! refresh_web_backup_inventory ||
    ! jq -e '
        .backups | length == 3
        and .[0].filename == "corosync-20260726T140000Z-103.conf"
        and .[0].integrity == "invalid"
    ' "$TAILMOX_WEB_ROOT/backups.json" >/dev/null; then
    printf 'FAIL: dashboard inventory did not refresh or flag an invalid backup\n'
    exit 1
fi

printf 'PASS: dashboard embeds the terminal and publishes safe backup metadata\n'
