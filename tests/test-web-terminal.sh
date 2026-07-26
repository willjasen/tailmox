#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"
export TAILMOX_SYSTEMD_DIR="$TEST_LOG_DIR/systemd"
mkdir -p "$TAILMOX_SYSTEMD_DIR"

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
EXPECTED_OUTPUT=$'Tailmox web server started.\nhttps://tailmox.risk-mermaid.ts.net:8669/'

if [[ "$OUTPUT" != "$EXPECTED_OUTPUT" ]]; then
    printf 'FAIL: launcher output did not contain only the status and service URL\n'
    printf 'Actual output:\n%s\n' "$OUTPUT"
    exit 1
fi

if [[ ! -f "$TAILMOX_SYSTEMD_DIR/tailmox-web.service" ]]; then
    printf 'FAIL: systemd service was not installed\n'
    exit 1
fi

if ! grep -Fxq 'enable --now tailmox-web.service' "$SYSTEMCTL_CALLS"; then
    printf 'FAIL: systemd service was not enabled and started\n'
    exit 1
fi

if ! grep -Fxq \
    'serve --service=svc:tailmox --bg --yes --https=8669 http://127.0.0.1:8670' \
    "$TAILSCALE_CALLS"; then
    printf 'FAIL: web terminal was not exposed through the Tailmox Tailscale service\n'
    exit 1
fi

printf 'PASS: web terminal starts persistently and prints only its tailnet URL\n'
