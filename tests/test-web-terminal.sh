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
WEB_SERVICE_ACTIVE=false

function systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
    if [[ "${1:-}" == "is-active" ]]; then
        [[ "$WEB_SERVICE_ACTIVE" == "true" ]]
    fi
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

if grep -Fq -- '--base-path' "$TAILMOX_SYSTEMD_DIR/tailmox-web.service"; then
    printf 'FAIL: ttyd expected a path prefix that Tailscale Serve removes\n'
    exit 1
fi

if grep -Fq -- '--writable' "$TAILMOX_SYSTEMD_DIR/tailmox-web.service"; then
    printf 'FAIL: ttyd allowed browser input to the host process\n'
    exit 1
fi

if ! grep -Fq -- '--url-arg' "$TAILMOX_SYSTEMD_DIR/tailmox-web.service" ||
    ! grep -Fq -- '/opt/tailmox/tailmox-web-terminal' \
        "$TAILMOX_SYSTEMD_DIR/tailmox-web.service"; then
    printf 'FAIL: ttyd did not use the action-restricted web terminal launcher\n'
    exit 1
fi

if ! grep -Fxq 'enable tailmox-web.service' "$SYSTEMCTL_CALLS" ||
    ! grep -Fxq 'restart tailmox-web.service' "$SYSTEMCTL_CALLS"; then
    printf 'FAIL: systemd service was not enabled and restarted\n'
    exit 1
fi

WEB_SERVICE_ACTIVE=true
SYSTEMCTL_CALL_COUNT=$(wc -l < "$SYSTEMCTL_CALLS")
TAILSCALE_SERVE_CALL_COUNT=$(grep -c '^serve ' "$TAILSCALE_CALLS")
OUTPUT=$(start_web_terminal)
EXPECTED_OUTPUT=$'Tailmox web server is already running.\nhttps://prox1.risk-mermaid.ts.net:8669/'

if [[ "$OUTPUT" != "$EXPECTED_OUTPUT" ]]; then
    printf 'FAIL: start did not report the URL of the already-running web server\n'
    exit 1
fi
if [[ "$(wc -l < "$SYSTEMCTL_CALLS")" -ne $((SYSTEMCTL_CALL_COUNT + 1)) ||
    "$(grep -c '^serve ' "$TAILSCALE_CALLS")" -ne "$TAILSCALE_SERVE_CALL_COUNT" ]]; then
    printf 'FAIL: starting an already-running web server changed its state\n'
    exit 1
fi
WEB_SERVICE_ACTIVE=false

if ! grep -Fxq \
    "serve --bg --yes --https=8669 --set-path=/ $TAILMOX_WEB_ROOT" \
    "$TAILSCALE_CALLS"; then
    printf 'FAIL: dashboard was not exposed through the host Tailscale name\n'
    exit 1
fi

printf '%s\n' \
    '[Unit]' \
    'Description=Tailmox web terminal' \
    'ExecStart=/opt/tailmox/tailmox-web-terminal' \
    > "$TAILMOX_SYSTEMD_DIR/tailmox-web.service"
OUTPUT=$(stop_web_terminal)

if [[ "$OUTPUT" != 'Tailmox web server stopped.' ]]; then
    printf 'FAIL: stop did not report success\n'
    exit 1
fi

if ! grep -Fxq 'serve --https=8669 off' "$TAILSCALE_CALLS" ||
    ! grep -Fxq 'disable --now tailmox-web.service' "$SYSTEMCTL_CALLS"; then
    printf 'FAIL: stop did not remove the listener and disable the service\n'
    exit 1
fi

printf '%s\n' \
    '[Unit]' \
    'Description=Unrelated service' \
    'ExecStart=/usr/local/bin/unrelated' \
    > "$TAILMOX_SYSTEMD_DIR/tailmox-web.service"
TAILSCALE_CALL_COUNT=$(wc -l < "$TAILSCALE_CALLS")
SYSTEMCTL_CALL_COUNT=$(wc -l < "$SYSTEMCTL_CALLS")

if stop_web_terminal >/dev/null 2>&1; then
    printf 'FAIL: stop accepted an unrelated same-named service\n'
    exit 1
fi
if [[ "$(wc -l < "$TAILSCALE_CALLS")" -ne "$TAILSCALE_CALL_COUNT" ||
    "$(wc -l < "$SYSTEMCTL_CALLS")" -ne "$SYSTEMCTL_CALL_COUNT" ]]; then
    printf 'FAIL: guarded stop changed service or listener state\n'
    exit 1
fi

if ! grep -Fxq \
    'serve --bg --yes --https=8669 --set-path=/terminal http://127.0.0.1:8670' \
    "$TAILSCALE_CALLS"; then
    printf 'FAIL: web terminal was not mounted beneath the dashboard\n'
    exit 1
fi

if ! grep -Fxq \
    'serve --bg --yes --https=8669 --set-path=/monitor http://127.0.0.1:8671' \
    "$TAILSCALE_CALLS"; then
    printf 'FAIL: monitor event stream was not mounted beneath the dashboard\n'
    exit 1
fi

for asset in index.html tailmox.css tailmox.js backups.json; do
    if [[ ! -f "$TAILMOX_WEB_ROOT/$asset" ]]; then
        printf 'FAIL: dashboard asset %s was not installed\n' "$asset"
        exit 1
    fi
done

if ! grep -Fq 'id="run-test"' "$TAILMOX_WEB_ROOT/index.html" ||
    ! grep -Fq 'id="create-backup"' "$TAILMOX_WEB_ROOT/index.html" ||
    ! grep -Fq 'id="run-cluster"' "$TAILMOX_WEB_ROOT/index.html" ||
    ! grep -Fq 'id="monitor-health"' "$TAILMOX_WEB_ROOT/index.html" ||
    ! grep -Fq 'id="monitor-database-size"' "$TAILMOX_WEB_ROOT/index.html" ||
    ! grep -Fq 'new EventSource("monitor/events")' "$TAILMOX_WEB_ROOT/tailmox.js" ||
    ! grep -Fq 'analytics.databaseSizeBytes' "$TAILMOX_WEB_ROOT/tailmox.js" ||
    ! grep -Fq 'addEventListener("backups"' "$TAILMOX_WEB_ROOT/tailmox.js" ||
    grep -Fq 'setInterval(loadBackups' "$TAILMOX_WEB_ROOT/tailmox.js" ||
    ! grep -Fq 'terminal/?arg=test' "$TAILMOX_WEB_ROOT/tailmox.js" ||
    ! grep -Fq 'terminal/?arg=backup-create' "$TAILMOX_WEB_ROOT/tailmox.js" ||
    ! grep -Fq 'terminal/?arg=cluster' "$TAILMOX_WEB_ROOT/tailmox.js"; then
    printf 'FAIL: dashboard workflows or live monitor analytics were not installed\n'
    exit 1
fi

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

printf 'PASS: dashboard embeds read-only command output and publishes live monitor and safe backup metadata\n'
