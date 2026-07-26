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
