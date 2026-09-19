#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_DIR"
export TAILMOX_MIN_TAILSCALE_VERSION=1.86.0
source "$ROOT_DIR/tailmox.sh"

tailscale_version_at_least 1.86.0 1.86.0 ||
    { printf 'FAIL: minimum Tailscale version was rejected\n' >&2; exit 1; }
tailscale_version_at_least 1.90.0 1.86.0 ||
    { printf 'FAIL: newer Tailscale version was rejected\n' >&2; exit 1; }
if tailscale_version_at_least 1.85.9 1.86.0; then
    printf 'FAIL: older Tailscale version was accepted\n' >&2
    exit 1
fi
if tailscale_version_at_least invalid 1.86.0; then
    printf 'FAIL: malformed Tailscale version was accepted\n' >&2
    exit 1
fi

printf 'PASS: Tailscale Services minimum version is enforced\n'
