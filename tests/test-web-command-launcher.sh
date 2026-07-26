#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_COMMAND="$TEST_DIR/mock-command"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "tailmox:%s\n" "$*"' > "$MOCK_COMMAND"
chmod +x "$MOCK_COMMAND"

TAILMOX_COMMAND="$MOCK_COMMAND" \
    "$TEST_ROOT/tailmox-web-terminal" > "$TEST_DIR/idle-output" &
IDLE_PID=$!
for _ in {1..20}; do
    [[ -s "$TEST_DIR/idle-output" ]] && break
    sleep 0.05
done
idle_output=$(cat "$TEST_DIR/idle-output")
kill "$IDLE_PID"
wait "$IDLE_PID" 2>/dev/null || true

if [[ "$idle_output" == *"Tailmox command output is ready."* ]] &&
    [[ "$idle_output" == *"This view is read-only"* ]] &&
    [[ "$idle_output" != *"tailmox:"* ]]; then
    printf 'PASS: opening the web terminal shows an idle read-only view\n'
else
    printf 'FAIL: opening the web terminal did not show an idle read-only view\n'
    exit 1
fi

if test_output=$(
    TAILMOX_COMMAND="$MOCK_COMMAND" \
        "$TEST_ROOT/tailmox-web-terminal" test
) &&
    [[ "$test_output" == "tailmox:test" ]]; then
    printf 'PASS: web test action runs tailmox test\n'
else
    printf 'FAIL: web test action runs tailmox test\n'
    exit 1
fi

if backup_output=$(
    TAILMOX_COMMAND="$MOCK_COMMAND" \
        "$TEST_ROOT/tailmox-web-terminal" backup-create
) &&
    [[ "$backup_output" == "tailmox:backups create" ]]; then
    printf 'PASS: web backup action runs tailmox backups create\n'
else
    printf 'FAIL: web backup action runs tailmox backups create\n'
    exit 1
fi

if cluster_output=$(
    TAILMOX_COMMAND="$MOCK_COMMAND" \
        "$TEST_ROOT/tailmox-web-terminal" cluster
) &&
    [[ "$cluster_output" == "tailmox:cluster" ]]; then
    printf 'PASS: web cluster action runs tailmox cluster\n'
else
    printf 'FAIL: web cluster action runs tailmox cluster\n'
    exit 1
fi

if TAILMOX_COMMAND="$MOCK_COMMAND" \
    "$TEST_ROOT/tailmox-web-terminal" unsupported >/dev/null 2>&1; then
    printf 'FAIL: unsupported web actions are rejected\n'
    exit 1
else
    printf 'PASS: unsupported web actions are rejected\n'
fi
