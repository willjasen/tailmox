#!/usr/bin/env bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

BIN_DIR="$TEST_DIR/bin"

if ! TAILMOX_BIN_DIR="$BIN_DIR" "$TEST_ROOT/tailmox" --help >/dev/null 2>&1; then
    printf 'FAIL: local launcher did not bootstrap the global command\n'
    exit 1
fi

if [[ ! -L "$BIN_DIR/tailmox" ]]; then
    printf 'FAIL: bootstrap did not create the tailmox command symlink\n'
    exit 1
fi

if [[ "$(readlink "$BIN_DIR/tailmox")" != "$TEST_ROOT/tailmox" ]]; then
    printf 'FAIL: bootstrapped command does not point to the project launcher\n'
    exit 1
fi

if ! TAILMOX_BIN_DIR="$BIN_DIR" "$BIN_DIR/tailmox" --help >/dev/null 2>&1; then
    printf 'FAIL: bootstrapped tailmox command is not runnable\n'
    exit 1
fi

printf 'PASS: local launcher bootstraps a runnable tailmox command\n'

CONFLICT_DIR="$TEST_DIR/conflict-bin"
mkdir -p "$CONFLICT_DIR"
printf 'unrelated command\n' >"$CONFLICT_DIR/tailmox"

if TAILMOX_BIN_DIR="$CONFLICT_DIR" "$TEST_ROOT/tailmox" --help >/dev/null 2>&1; then
    printf 'FAIL: bootstrap overwrote an unrelated existing command\n'
    exit 1
fi

if [[ "$(sed -n '1p' "$CONFLICT_DIR/tailmox")" != "unrelated command" ]]; then
    printf 'FAIL: bootstrap changed an unrelated existing command\n'
    exit 1
fi

printf 'PASS: bootstrap preserves an unrelated existing command\n'

DISPATCH_DIR="$TEST_DIR/dispatch"
mkdir -p "$DISPATCH_DIR"
cp "$TEST_ROOT/tailmox" "$DISPATCH_DIR/tailmox"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ -n "${TAILMOX_DISPATCH_CALLS:-}" ]]; then' \
    '    printf "%s\n" "$*" >> "$TAILMOX_DISPATCH_CALLS"' \
    'fi' \
    'if [[ "${TAILMOX_FAIL_WEB_STOP:-false}" == "true" && "${1:-}" == "--web-stop" ]]; then' \
    '    exit 1' \
    'fi' \
    'printf "tailmox.sh"' \
    'for argument in "$@"; do printf " <%s>" "$argument"; done' \
    'printf "\n"' \
    > "$DISPATCH_DIR/tailmox.sh"
chmod +x "$DISPATCH_DIR/tailmox" "$DISPATCH_DIR/tailmox.sh"

SHORT_OUTPUT=$(TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" serve)
EXPLICIT_OUTPUT=$(TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" serve start)
OPTION_OUTPUT=$(TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" serve start --auth-key test-key)
SHORT_OPTION_OUTPUT=$(TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" serve --auth-key test-key)

if [[ "$SHORT_OUTPUT" != 'tailmox.sh' ||
    "$EXPLICIT_OUTPUT" != 'tailmox.sh' ||
    "$OPTION_OUTPUT" != 'tailmox.sh <--auth-key> <test-key>' ||
    "$SHORT_OPTION_OUTPUT" != 'tailmox.sh <--auth-key> <test-key>' ]]; then
    printf 'FAIL: serve did not default to the explicit start action\n'
    exit 1
fi

printf 'PASS: serve defaults to the explicit start action\n'

DISPATCH_CALLS="$TEST_DIR/dispatch-calls"
RESTART_OUTPUT=$(TAILMOX_DISPATCH_CALLS="$DISPATCH_CALLS" \
    TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" serve restart)

if [[ "$RESTART_OUTPUT" != $'tailmox.sh <--web-stop>\ntailmox.sh' ]] ||
    [[ "$(sed -n '1p' "$DISPATCH_CALLS")" != '--web-stop' ]] ||
    [[ -n "$(sed -n '2p' "$DISPATCH_CALLS")" ]]; then
    printf 'FAIL: serve restart did not stop and then start the web server\n'
    exit 1
fi

if TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" \
    serve restart unexpected >/dev/null 2>&1; then
    printf 'FAIL: serve restart accepted unexpected arguments\n'
    exit 1
fi

FAILED_RESTART_CALLS="$TEST_DIR/failed-restart-calls"
if TAILMOX_DISPATCH_CALLS="$FAILED_RESTART_CALLS" TAILMOX_FAIL_WEB_STOP=true \
    TAILMOX_BIN_DIR="$BIN_DIR" "$DISPATCH_DIR/tailmox" \
    serve restart >/dev/null 2>&1; then
    printf 'FAIL: serve restart succeeded after stop failed\n'
    exit 1
fi
if [[ "$(wc -l < "$FAILED_RESTART_CALLS")" -ne 1 ]] ||
    [[ "$(sed -n '1p' "$FAILED_RESTART_CALLS")" != '--web-stop' ]]; then
    printf 'FAIL: serve restart attempted to start after stop failed\n'
    exit 1
fi

printf 'PASS: serve restart stops and then starts the web server\n'
