#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_LOG_DIR=$(mktemp -d)
FIFO_WRITER_PID=""
trap '[[ -n "$FIFO_WRITER_PID" ]] && kill "$FIFO_WRITER_PID" 2>/dev/null || true; rm -rf "$TEST_LOG_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_LOG_DIR"
export TAILMOX_CONFIRMATION_TIMEOUT_SECONDS=1

source "$TEST_ROOT/tailmox.sh"

CONFIRMATION_DEVICE="$TEST_LOG_DIR/confirmation-input"
mkfifo "$CONFIRMATION_DEVICE"
export TAILMOX_CONFIRMATION_DEVICE="$CONFIRMATION_DEVICE"

sleep 3 > "$CONFIRMATION_DEVICE" &
FIFO_WRITER_PID=$!

START_TIME=$(date +%s)
if CONFIRMATION_OUTPUT=$(confirm_icmp_warning_override 2>&1); then
    printf 'FAIL: setup continued after confirmation timed out\n'
    exit 1
fi
ELAPSED_TIME=$(($(date +%s) - START_TIME))

kill "$FIFO_WRITER_PID" 2>/dev/null || true
wait "$FIFO_WRITER_PID" 2>/dev/null || true
FIFO_WRITER_PID=""

if [[ "$ELAPSED_TIME" -ge 3 ]]; then
    printf 'FAIL: confirmation did not honor the configured timeout\n'
    exit 1
fi

if [[ "$CONFIRMATION_OUTPUT" != *"Confirmation timed out after 1 seconds. Setup cancelled"* ]]; then
    printf 'FAIL: timeout did not clearly report that setup was cancelled\n'
    exit 1
fi

printf 'PASS: setup is cancelled when confirmation times out\n'

rm "$CONFIRMATION_DEVICE"
printf 'PROCEED\n' > "$CONFIRMATION_DEVICE"

if ! confirm_icmp_warning_override >/dev/null 2>&1; then
    printf 'FAIL: exact PROCEED confirmation was rejected before the timeout\n'
    exit 1
fi

printf 'PASS: exact PROCEED confirmation continues setup before the timeout\n'

printf 'proceed\n' > "$CONFIRMATION_DEVICE"

if confirm_icmp_warning_override >/dev/null 2>&1; then
    printf 'FAIL: non-exact confirmation continued setup\n'
    exit 1
fi

printf 'PASS: confirmation still requires exact PROCEED input\n'
