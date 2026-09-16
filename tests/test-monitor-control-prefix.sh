#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$ROOT_DIR/tailmox-monitor.py"

grep -Fq 'window.location.pathname.startsWith("/control/") ? "/control" : ""' "$MONITOR"
grep -Fq 'fetch(`${apiPrefix}${path}`' "$MONITOR"
grep -Fq 'fetch(`${apiPrefix}/api/influxdb`' "$MONITOR"
grep -Fq 'href="./">Back to monitor' "$MONITOR"
grep -Fq 'id="identityDetails" hidden' "$MONITOR"
grep -Fq 'Post-quantum ML-KEM-768 + X25519' "$MONITOR"
grep -Fq 'identity.signingKeyConfigured ? "Dedicated Ed25519 key loaded"' "$MONITOR"

printf 'monitor control-prefix tests passed\n'
