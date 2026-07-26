#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"
export TAILMOX_WEB_ROOT="$TEST_LOG_DIR/web"

source "$TEST_ROOT/tailmox.sh"

HOSTNAME="pve-local"
MOCK_TAGS='["tag:tailmox"]'
CHECK_LOG=""

function check_if_supported_proxmox_is_installed() { return 0; }
function check_script_directory() { return 0; }
function command() { return 0; }
function check_all_peers_online() {
    CHECK_LOG+="peer-online "
    return 0
}
function ensure_ping_reachability() {
    CHECK_LOG+="ping:${2:-all other Tailmox peers} "
    return 0
}
function are_hosts_tcp_port_8006_reachable() {
    CHECK_LOG+="8006:$2 "
    return 0
}
function are_hosts_tcp_port_443_reachable() {
    CHECK_LOG+="443:$2 "
    return 0
}
function check_local_node_cluster_status() { return 0; }
function tailscale() {
    if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
        jq -n --argjson tags "$MOCK_TAGS" '{
            BackendState: "Running",
            Self: {
                Online: true,
                Tags: $tags,
                DNSName: "pve-local.example.ts.net."
            },
            Peer: {
                remote: {
                    HostName: "pve-remote",
                    TailscaleIPs: ["100.64.0.2"],
                    DNSName: "pve-remote.example.ts.net.",
                    Online: true,
                    Tags: ["tag:tailmox"]
                }
            }
        }'
        return 0
    fi

    if [[ "${1:-}" == "ip" && "${2:-}" == "-4" ]]; then
        printf '%s\n' "100.64.0.1"
        return 0
    fi

    return 1
}

PASS_COUNT=0
FAIL_COUNT=0

if test_setup_safely &&
    [[ "$CHECK_LOG" == \
"ping:the local Proxmox host 8006:the local Proxmox host 443:the local Proxmox host peer-online ping:all other Tailmox peers 8006:all other Tailmox peers 443:all other Tailmox peers " ]]; then
    printf 'PASS: local Tailscale and Proxmox checks run before remote peer checks\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: local Tailscale and Proxmox checks run before remote peer checks (%s)\n' "$CHECK_LOG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

MOCK_TAGS='[]'
CHECK_LOG=""
if test_setup_safely >/dev/null 2>&1; then
    printf 'FAIL: missing local tag:tailmox identity fails the self-test\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
elif [[ -n "$CHECK_LOG" ]]; then
    printf 'FAIL: missing local tag:tailmox identity fails before network checks\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf 'PASS: missing local tag:tailmox identity fails before network checks\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
