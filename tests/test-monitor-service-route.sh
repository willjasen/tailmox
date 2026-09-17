#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT_DIR/tailmox.sh"

if ! grep -Fq \
    'configure_tailscale_serve "--service=svc:${TAILMOX_TAILSCALE_SERVICE_NAME}" --bg --https=443 localhost:8088' \
    "$INSTALLER"; then
    printf 'FAIL: configurable shared Tailmox service does not route HTTPS port 443 to the monitor\n'
    exit 1
fi

if ! grep -Fq \
    'TAILMOX_TAILSCALE_SERVICE_NAME="${TAILMOX_TAILSCALE_SERVICE_NAME:-tailmox}"' \
    "$INSTALLER"; then
    printf 'FAIL: shared Tailmox service does not retain a compatible default\n'
    exit 1
fi

if grep -Fq \
    'tailscale serve --service=svc:tailmox https+insecure://localhost:8006' \
    "$INSTALLER" ||
    grep -Fq \
        'tailscale serve --service=svc:tailmox --https=8088' \
        "$INSTALLER"; then
    printf 'FAIL: obsolete shared Tailmox service route is still configured\n'
    exit 1
fi

printf 'PASS: configurable shared Tailmox service routes HTTPS port 443 to the monitor\n'
