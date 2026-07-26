#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

SYSTEMD_DIR="$TEST_TMP/systemd"
MOCK_BIN="$TEST_TMP/bin"
SYSTEMCTL_CALLS="$TEST_TMP/systemctl-calls"
DATABASE="$TEST_TMP/monitor.sqlite3"
mkdir -p "$SYSTEMD_DIR" "$MOCK_BIN"
printf '%s\n' 'preserved monitor history' > "$DATABASE"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$SYSTEMCTL_CALLS"' \
    > "$MOCK_BIN/systemctl"
chmod +x "$MOCK_BIN/systemctl"

export PATH="$MOCK_BIN:$PATH"
export SYSTEMCTL_CALLS

TAILMOX_SYSTEMD_DIR="$SYSTEMD_DIR" \
TAILMOX_MONITOR_DB="$DATABASE" \
    "$TEST_ROOT/tailmox" monitor install >/dev/null

SERVICE="$SYSTEMD_DIR/tailmox-monitor.service"
if [[ ! -f "$SERVICE" ]] ||
    ! grep -Fq 'ExecStart=/usr/local/bin/tailmox monitor --mode auto' "$SERVICE" ||
    ! grep -Fxq 'daemon-reload' "$SYSTEMCTL_CALLS" ||
    ! grep -Fxq 'enable tailmox-monitor.service' "$SYSTEMCTL_CALLS" ||
    ! grep -Fxq 'restart tailmox-monitor.service' "$SYSTEMCTL_CALLS"; then
    printf 'FAIL: monitor service was not safely installed and started\n'
    exit 1
fi

TAILMOX_SYSTEMD_DIR="$SYSTEMD_DIR" \
TAILMOX_MONITOR_DB="$DATABASE" \
    "$TEST_ROOT/tailmox" monitor uninstall >/dev/null

if [[ -e "$SERVICE" ]] ||
    ! grep -Fxq 'disable --now tailmox-monitor.service' "$SYSTEMCTL_CALLS"; then
    printf 'FAIL: monitor service was not stopped and removed\n'
    exit 1
fi

if [[ ! -f "$DATABASE" ]] ||
    [[ "$(cat "$DATABASE")" != "preserved monitor history" ]]; then
    printf 'FAIL: uninstall removed monitor history\n'
    exit 1
fi

TAILMOX_SYSTEMD_DIR="$SYSTEMD_DIR" \
    "$TEST_ROOT/tailmox" monitor uninstall >/dev/null

printf '%s\n' \
    '[Unit]' \
    'Description=Unrelated monitor' \
    > "$SERVICE"
if TAILMOX_SYSTEMD_DIR="$SYSTEMD_DIR" \
    "$TEST_ROOT/tailmox" monitor uninstall >/dev/null 2>&1; then
    printf 'FAIL: uninstall removed an unrelated service\n'
    exit 1
fi
if [[ ! -f "$SERVICE" ]]; then
    printf 'FAIL: unrelated service was removed\n'
    exit 1
fi

printf 'PASS: monitor service installs and uninstalls without deleting history\n'
