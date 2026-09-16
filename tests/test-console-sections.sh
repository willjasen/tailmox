#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for section in intro staging settings monitor; do
    grep -Fq "value=\"$section\"" "$ROOT_DIR/web/index.html"
    grep -Fq "data-page=\"$section\"" "$ROOT_DIR/web/index.html"
done

grep -Fq 'src="/control/editInfluxDB"' "$ROOT_DIR/web/index.html"
grep -Fq 'fetch("/control/api/security"' "$ROOT_DIR/web/tailmox.js"
grep -Fq 'fetch(`/control/api/actions/${action}`' "$ROOT_DIR/web/tailmox.js"
grep -Fq 'Existing plaintext settings remain active' "$ROOT_DIR/web/index.html"

printf 'console section tests passed\n'
