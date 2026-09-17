#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/release/tailmox-main" "$TEST_DIR/bin"
cp "$ROOT_DIR/tailmox" "$ROOT_DIR/tailmox.sh" "$ROOT_DIR/tailmox-monitor.service" \
    "$ROOT_DIR/tailmox-monitor.py" "$TEST_DIR/release/tailmox-main/"
tar -czf "$TEST_DIR/tailmox.tar.gz" -C "$TEST_DIR/release" tailmox-main

cat > "$TEST_DIR/bin/pveversion" <<'EOF'
#!/usr/bin/env bash
printf 'pve-manager/9.0.1/test\n'
EOF
chmod +x "$TEST_DIR/bin/pveversion"
cat > "$TEST_DIR/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == status ]]; then
    printf '{"Self":{"DNSName":"pve1.example.ts.net."}}\n'
fi
EOF
chmod +x "$TEST_DIR/bin/tailscale"

cat > "$TEST_DIR/release/tailmox-main/tailmox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAILMOX_STAGE_CALLS"
EOF
chmod +x "$TEST_DIR/release/tailmox-main/tailmox"
tar -czf "$TEST_DIR/tailmox.tar.gz" -C "$TEST_DIR/release" tailmox-main

INSTALL_DIR="$TEST_DIR/opt/tailmox"
COMMAND_DIR="$TEST_DIR/usr-local-bin"
IDENTITY_FILE="$TEST_DIR/identity.txt"
STAGE_CALLS="$TEST_DIR/stage-calls"
printf 'existing identity\n' > "$IDENTITY_FILE"
export TAILMOX_STAGE_CALLS="$STAGE_CALLS"
OUTPUT=$(PATH="$TEST_DIR/bin:$PATH" \
    TAILMOX_ALLOW_NON_ROOT=true \
    TAILMOX_ARCHIVE_URL="file://$TEST_DIR/tailmox.tar.gz" \
    TAILMOX_INSTALL_DIR="$INSTALL_DIR" \
    TAILMOX_BIN_DIR="$COMMAND_DIR" \
    TAILMOX_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    bash "$ROOT_DIR/install.sh")

[[ -x "$INSTALL_DIR/tailmox" ]]
[[ -x "$INSTALL_DIR/tailmox.sh" ]]
[[ -L "$COMMAND_DIR/tailmox" ]]
[[ "$(readlink "$COMMAND_DIR/tailmox")" == "$INSTALL_DIR/tailmox" ]]
grep -Fq 'Run tailmox cluster when every host is ready.' <<< "$OUTPUT"
grep -Fq 'Monitor: https://pve1.example.ts.net:8088/monitor/' <<< "$OUTPUT"
grep -Fxq 'stage' "$STAGE_CALLS"

printf 'old release marker\n' > "$INSTALL_DIR/old-release"
UPDATE_OUTPUT=$(PATH="$TEST_DIR/bin:$PATH" \
    TAILMOX_ALLOW_NON_ROOT=true \
    TAILMOX_ARCHIVE_URL="file://$TEST_DIR/tailmox.tar.gz" \
    TAILMOX_INSTALL_DIR="$INSTALL_DIR" \
    TAILMOX_BIN_DIR="$COMMAND_DIR" \
    TAILMOX_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    bash "$ROOT_DIR/install.sh")
[[ ! -e "$INSTALL_DIR/old-release" ]]
grep -Fq 'Tailmox is updated from the dev branch.' <<< "$UPDATE_OUTPUT"

[[ "$(wc -l < "$STAGE_CALLS")" -eq 2 ]]
printf 'PASS: one-line installer deploys, updates, stages, and preserves identity\n'
