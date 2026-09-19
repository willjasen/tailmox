#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare a booted linked clone for Tailmox testing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/prepare-linked-clone.sh" "$@"
