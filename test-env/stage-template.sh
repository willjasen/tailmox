#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare a fresh nested Proxmox installation to become a reusable Tailmox
# testing image. This script runs inside the nested Proxmox guest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/prepare-proxmox-test-guest.sh" "$@"
