#!/usr/bin/env bash
set -Eeuo pipefail

# Download the pinned IPFS image when needed and create the Proxmox template.
# This script runs on the outer Proxmox host.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/create-vm-template.sh" "$@"
