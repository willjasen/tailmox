#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_STATE_DIR/log"
export TAILMOX_STATE_FILE="$TEST_STATE_DIR/state.json"
mkdir -p "$TAILMOX_LOG_DIR"

# shellcheck source=../tailmox.sh
source "$TEST_ROOT/tailmox.sh"

SPECIAL_PASSWORD='Amp&Plus+Percent% Dollar$ Bracket[ Quote" Backslash\ Bang!'

curl() {
    printf '%s\n' "$@" >>"$TEST_STATE_DIR/curl-arguments"
    if [[ "$*" == *"/access/ticket"* ]]; then
        printf '%s\n' '{"data":{"ticket":"test-ticket","CSRFPreventionToken":"test-csrf"}}'
    else
        printf '%s\n' '{"data":[{"type":"cluster","name":"tailmox"}]}'
    fi
}

if ! check_remote_node_cluster_status_via_api \
    "pve-a1" "root@pam" "$SPECIAL_PASSWORD" >/dev/null; then
    printf 'FAIL: API cluster check rejected a complex password\n' >&2
    exit 1
fi

grep -Fqx -- '--data-urlencode' "$TEST_STATE_DIR/curl-arguments" || {
    printf 'FAIL: API credentials were not form encoded by curl\n' >&2
    exit 1
}
grep -Fqx -- "password=$SPECIAL_PASSWORD" "$TEST_STATE_DIR/curl-arguments" || {
    printf 'FAIL: API password was not passed as one literal curl argument\n' >&2
    exit 1
}

expect() {
    local received_password
    IFS= read -r -d '' received_password || true
    [[ "$received_password" == "$SPECIAL_PASSWORD" ]] || {
        printf 'FAIL: Expect did not receive the literal password\n' >&2
        return 1
    }
    [[ "$1" == '-c' ]] || return 1
    [[ "$2" != *"$SPECIAL_PASSWORD"* ]] || {
        printf 'FAIL: password was interpolated into Tcl source\n' >&2
        return 1
    }
    [[ "$3" == 'pve-a1.example.ts.net' ]]
    [[ "$4" == '100.64.0.2' ]]
    [[ "$5" == 'AA:BB:CC' ]]
}

join_remote_proxmox_cluster \
    'pve-a1.example.ts.net' '100.64.0.2' 'AA:BB:CC' "$SPECIAL_PASSWORD"

printf 'PASS: complex Proxmox passwords remain literal in API and Expect calls\n'
