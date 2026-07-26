#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"

source "$TEST_ROOT/tailmox.sh"

FAIL_PORT=""
FAIL_IP=""

function nc() {
    local ip="${4}"
    local port="${5}"

    [[ "$ip" != "$FAIL_IP" || "$port" != "$FAIL_PORT" ]]
}

PEERS='[
  {
    "hostname": "pve1",
    "ip": "100.64.0.1"
  },
  {
    "hostname": "pve2",
    "ip": "100.64.0.2"
  }
]'

if ! OUTPUT_8006=$(are_hosts_tcp_port_8006_reachable "$PEERS" "all other Tailmox peers" 2>&1); then
    printf 'FAIL: available TCP port 8006 was reported unavailable\n'
    exit 1
fi

if ! OUTPUT_443=$(are_hosts_tcp_port_443_reachable "$PEERS" "all other Tailmox peers" 2>&1); then
    printf 'FAIL: available TCP port 443 was reported unavailable\n'
    exit 1
fi

for peer_data in "pve1 100.64.0.1" "pve2 100.64.0.2"; do
    read -r peer ip <<< "$peer_data"
    printf -v expected_heading '%b' "${BLUE} - $peer ($ip)${RESET}"

    if [[ "$(printf '%s\n%s\n' "$OUTPUT_8006" "$OUTPUT_443" | grep -Fxc -- "$expected_heading")" -ne 2 ]]; then
        printf 'FAIL: TCP checks did not print one heading per peer and port\n'
        exit 1
    fi
done

if [[ "$(printf '%s\n' "$OUTPUT_8006" | grep -Ec -- 'TCP port 8006 is available; latency [0-9]+\.[0-9]{3} ms\.')" -ne 2 ]] \
    || [[ "$(printf '%s\n' "$OUTPUT_443" | grep -Ec -- 'TCP port 443 is available; latency [0-9]+\.[0-9]{3} ms\.')" -ne 2 ]]; then
    printf 'FAIL: successful TCP results did not include latency\n'
    exit 1
fi

FAIL_IP="100.64.0.2"
FAIL_PORT="443"
if FAILURE_OUTPUT=$(are_hosts_tcp_port_443_reachable "$PEERS" "all other Tailmox peers" 2>&1); then
    printf 'FAIL: unavailable TCP port 443 did not fail closed\n'
    exit 1
fi

if [[ "$(printf '%s\n' "$FAILURE_OUTPUT" | grep -Ec -- 'TCP port 443 is not available; latency [0-9]+\.[0-9]{3} ms\.')" -ne 1 ]]; then
    printf 'FAIL: failed TCP result did not include latency\n'
    exit 1
fi

printf 'PASS: TCP checks group nested results beneath each peer\n'
