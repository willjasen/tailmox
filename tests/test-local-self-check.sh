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
MOCK_MISSING_DEPENDENCY=""
MOCK_ICMP_WARNING=false
MOCK_CLUSTER_STATUS='Cluster information
-------------------
Name:             production
Quorate:          Yes'
CHECK_LOG=""

function check_if_supported_proxmox_is_installed() { return 0; }
function check_script_directory() { return 0; }
function command() {
    [[ "${1:-}" == "-v" && "${2:-}" != "$MOCK_MISSING_DEPENDENCY" ]]
}
function check_all_peers_online() {
    CHECK_LOG+="peer-online "
    return 0
}
function ensure_ping_reachability() {
    CHECK_LOG+="ping:${2:-all other Tailmox peers}:${3:-true} "
    if [[ "$MOCK_ICMP_WARNING" == true && "${3:-true}" == false ]]; then
        TAILMOX_ICMP_WARNINGS_RECORDED=true
    fi
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
function pvecm() {
    if [[ "${1:-}" == "status" ]]; then
        printf '%s\n' "$MOCK_CLUSTER_STATUS"
        return 0
    fi
    return 2
}
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
"ping:the local Proxmox host:false 8006:the local Proxmox host 443:the local Proxmox host peer-online ping:all other Tailmox peers:false 8006:all other Tailmox peers 443:all other Tailmox peers " ]]; then
    printf 'PASS: local Tailscale and Proxmox checks run before remote peer checks\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: local Tailscale and Proxmox checks run before remote peer checks (%s)\n' "$CHECK_LOG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

SETUP_OUTPUT=$(test_setup_safely)
if [[ "$SETUP_OUTPUT" == *"is available."* ]]; then
    printf 'FAIL: setup test reports dependencies that are already available\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf 'PASS: setup test does not report dependencies that are already available\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi

if [[ "$SETUP_OUTPUT" == *"This node is already part of the Proxmox cluster named: production."* ]]; then
    printf 'PASS: setup test reports existing Proxmox cluster membership\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: setup test reports existing Proxmox cluster membership\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

MOCK_CLUSTER_STATUS='Cannot initialize CMAP service
is this node part of a cluster?'
STANDALONE_OUTPUT=$(test_setup_safely)
STANDALONE_OUTPUT_ORDER=$(printf '%s\n' "$STANDALONE_OUTPUT" |
    sed $'s/\033\\[[0-9;]*m//g' |
    grep -Eo '4\. Peer connectivity|5\. Proxmox cluster status|This node is not part of any cluster\.|RESULT: Setup test passed')
EXPECTED_STANDALONE_OUTPUT_ORDER=$'4. Peer connectivity\n5. Proxmox cluster status\nThis node is not part of any cluster.\nRESULT: Setup test passed'
if [[ "$STANDALONE_OUTPUT_ORDER" == "$EXPECTED_STANDALONE_OUTPUT_ORDER" ]]; then
    printf 'PASS: setup test reports standalone host state after network checks\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: setup test reports standalone host state after network checks\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
MOCK_CLUSTER_STATUS='Cluster information
-------------------
Name:             production
Quorate:          Yes'

EXPECTED_SECTION_ORDER=$'1. Host readiness\n2. Tailscale identity\n3. Local host connectivity\n4. Peer connectivity\n5. Proxmox cluster status\nRESULT: Setup test passed'
ACTUAL_SECTION_ORDER=$(printf '%s\n' "$SETUP_OUTPUT" |
    sed $'s/\033\\[[0-9;]*m//g' |
    grep -Eo '1\. Host readiness|2\. Tailscale identity|3\. Local host connectivity|4\. Peer connectivity|5\. Proxmox cluster status|RESULT: Setup test passed')
if [[ "$ACTUAL_SECTION_ORDER" == "$EXPECTED_SECTION_ORDER" ]]; then
    printf 'PASS: setup test output separates its major phases in order\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: setup test output separates its major phases in order\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

MOCK_ICMP_WARNING=true
SETUP_WARNING_OUTPUT=$(test_setup_safely)
if [[ "$SETUP_WARNING_OUTPUT" == *$'\033[1;33m━━━ RESULT: Setup test passed with warnings'* ]]; then
    printf 'PASS: setup test reports ICMP warnings in its yellow result summary\n'
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf 'FAIL: setup test reports ICMP warnings in its yellow result summary\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
MOCK_ICMP_WARNING=false

if [[ "$SETUP_OUTPUT" == *"Skipped all mutating steps"* ]]; then
    printf 'FAIL: setup test omits the redundant skipped-steps summary\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf 'PASS: setup test omits the redundant skipped-steps summary\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi

MOCK_MISSING_DEPENDENCY="ttyd"
if SETUP_OUTPUT=$(test_setup_safely 2>&1); then
    printf 'FAIL: missing dependency fails the self-test\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
elif [[ "$SETUP_OUTPUT" != *"ttyd is missing"* ]]; then
    printf 'FAIL: missing dependency is reported\n'
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    printf 'PASS: missing dependency is reported\n'
    PASS_COUNT=$((PASS_COUNT + 1))
fi
MOCK_MISSING_DEPENDENCY=""

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
