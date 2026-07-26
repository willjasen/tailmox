#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"

source "$TEST_ROOT/tailmox.sh"

PING_TARGETS_FILE="$TEST_LOG_DIR/ping-targets"
PING_ARGS_FILE="$TEST_LOG_DIR/ping-args"
TAILSCALE_PING_TARGETS_FILE="$TEST_LOG_DIR/tailscale-ping-targets"
TAILSCALE_PING_ARGS_FILE="$TEST_LOG_DIR/tailscale-ping-args"
FAIL_PING_TARGET=""
FAIL_TAILSCALE_PING_TARGET=""
CONFIRM_OVERRIDE_RESULT=1

function confirm_icmp_warning_override() {
    return "$CONFIRM_OVERRIDE_RESULT"
}

function ping() {
    local target="${!#}"

    printf '%s\n' "$target" >> "$PING_TARGETS_FILE"
    printf '%s\n' "$*" >> "$PING_ARGS_FILE"
    sleep 1

    if [[ "$target" == "$FAIL_PING_TARGET" ]]; then
        printf '11 packets transmitted, 0 received, 100%% packet loss, time 5000ms\n'
        return 1
    fi

    printf '11 packets transmitted, 11 received, 0%% packet loss, time 5000ms\n'
    printf 'rtt min/avg/max/mdev = 1.000/2.000/3.000/0.100 ms\n'
    return 0
}

function tailscale() {
    local target="${!#}"

    if [[ "$1" != "ping" ]]; then
        printf 'Unexpected mocked tailscale command: %s\n' "$*" >&2
        return 1
    fi

    printf '%s\n' "$target" >> "$TAILSCALE_PING_TARGETS_FILE"
    printf '%s\n' "$*" >> "$TAILSCALE_PING_ARGS_FILE"
    sleep 1

    if [[ "$target" == "$FAIL_TAILSCALE_PING_TARGET" ]]; then
        printf 'no pong received\n'
        return 1
    fi

    printf 'pong from %s via 192.0.2.1:41641 in 2ms\n' "$target"
    return 0
}

OTHER_PEERS='[
  {
    "hostname": "pve1",
    "dnsName": "pve1.example.ts.net.",
    "ip": "100.64.0.1",
    "online": true
  },
  {
    "hostname": "pve2",
    "dnsName": "pve2.example.ts.net.",
    "ip": "100.64.0.2",
    "online": true
  },
  {
    "hostname": "pve3",
    "dnsName": "pve3.example.ts.net.",
    "ip": "100.64.0.3",
    "online": true
  }
]'

START_TIME=$(date +%s)
if ! FIRST_CHECK_OUTPUT=$(ensure_ping_reachability 2>&1); then
    printf 'FAIL: parallel DNS ping check returned failure\n'
    exit 1
fi
ELAPSED_TIME=$(($(date +%s) - START_TIME))

if [[ "$ELAPSED_TIME" -gt 2 ]]; then
    printf 'FAIL: peer connectivity checks did not run in parallel (%ss elapsed)\n' "$ELAPSED_TIME"
    exit 1
fi

sort "$PING_TARGETS_FILE" > "$TEST_LOG_DIR/actual-targets"
printf '%s\n' \
    "pve1.example.ts.net" \
    "pve1.example.ts.net" \
    "pve2.example.ts.net" \
    "pve2.example.ts.net" \
    "pve3.example.ts.net" \
    "pve3.example.ts.net" \
    > "$TEST_LOG_DIR/expected-targets"

if ! diff -u "$TEST_LOG_DIR/expected-targets" "$TEST_LOG_DIR/actual-targets"; then
    printf 'FAIL: peer pings did not use every Tailscale DNS name\n'
    exit 1
fi

if [[ "$(grep -c -- '-c 11 -i 0.5 -W 0.05 -w 6' "$PING_ARGS_FILE")" -ne 6 ]]; then
    printf 'FAIL: peer pings did not use the five-second sampling options\n'
    exit 1
fi

if [[ "$(grep -c -- '-s 56 ' "$PING_ARGS_FILE")" -ne 3 ]] \
    || [[ "$(grep -c -- '-s 1272 ' "$PING_ARGS_FILE")" -ne 3 ]]; then
    printf 'FAIL: peer pings did not test 64-byte and 1280-byte ICMP packets\n'
    exit 1
fi

sort "$TAILSCALE_PING_TARGETS_FILE" > "$TEST_LOG_DIR/actual-tailscale-targets"
printf '%s\n' \
    "pve1.example.ts.net" \
    "pve2.example.ts.net" \
    "pve3.example.ts.net" \
    > "$TEST_LOG_DIR/expected-tailscale-targets"

if ! diff -u "$TEST_LOG_DIR/expected-tailscale-targets" "$TEST_LOG_DIR/actual-tailscale-targets"; then
    printf 'FAIL: Tailscale path checks did not use every Tailscale DNS name\n'
    exit 1
fi

if [[ "$(grep -c -- '^ping --c 1 ' "$TAILSCALE_PING_ARGS_FILE")" -ne 3 ]]; then
    printf 'FAIL: Tailscale path checks did not use one default DISCO ping\n'
    exit 1
fi

for peer in pve1 pve2 pve3; do
    if [[ "$(printf '%s\n' "$FIRST_CHECK_OUTPUT" | grep -c -- "$peer .*64-byte ICMP: average latency 2.000 ms; maximum latency 3.000 ms")" -ne 1 ]] \
        || [[ "$(printf '%s\n' "$FIRST_CHECK_OUTPUT" | grep -c -- "$peer .*1280-byte ICMP: average latency 2.000 ms; maximum latency 3.000 ms")" -ne 1 ]]; then
        printf 'FAIL: peer ICMP results did not clearly report average and maximum latency by packet size\n'
        exit 1
    fi
done

printf 'PASS: all peers use Tailscale path checks and both ICMP packet sizes in parallel\n'

: > "$PING_TARGETS_FILE"
: > "$TAILSCALE_PING_TARGETS_FILE"
FAIL_TAILSCALE_PING_TARGET="pve2.example.ts.net"

if ensure_ping_reachability >/dev/null 2>&1; then
    printf 'FAIL: a failed Tailscale path check did not block progress\n'
    exit 1
fi

if [[ "$(wc -l < "$PING_TARGETS_FILE" | tr -d ' ')" -ne 6 ]] \
    || [[ "$(wc -l < "$TAILSCALE_PING_TARGETS_FILE" | tr -d ' ')" -ne 3 ]]; then
    printf 'FAIL: a failed Tailscale path check prevented other parallel checks from running\n'
    exit 1
fi

printf 'PASS: a failed Tailscale path check blocks progress after all parallel checks run\n'

: > "$PING_TARGETS_FILE"
FAIL_TAILSCALE_PING_TARGET=""
FAIL_PING_TARGET="pve2.example.ts.net"

if ensure_ping_reachability >/dev/null 2>&1; then
    printf 'FAIL: a missing 50 ms reply proceeded without confirmation\n'
    exit 1
fi

if [[ "$(wc -l < "$PING_TARGETS_FILE" | tr -d ' ')" -ne 6 ]]; then
    printf 'FAIL: an unreachable peer prevented other parallel probes from running\n'
    exit 1
fi

printf 'PASS: a missing 50 ms reply blocks progress after all parallel probes run\n'

CONFIRM_OVERRIDE_RESULT=0

if ! ensure_ping_reachability >/dev/null 2>&1; then
    printf 'FAIL: explicit confirmation did not override the ICMP warning\n'
    exit 1
fi

printf 'PASS: explicit confirmation overrides the ICMP warning\n'
