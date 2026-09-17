#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/repository" "$TEST_DIR/bin"
cp "$ROOT_DIR/tailmox" "$ROOT_DIR/tailmox.sh" "$ROOT_DIR/tailmox-monitor.service" \
    "$ROOT_DIR/tailmox-monitor.py" "$TEST_DIR/repository/"

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

cat > "$TEST_DIR/repository/tailmox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAILMOX_STAGE_CALLS"
EOF
chmod +x "$TEST_DIR/repository/tailmox"
git -C "$TEST_DIR/repository" init -q -b dev
git -C "$TEST_DIR/repository" config user.name 'Tailmox Tests'
git -C "$TEST_DIR/repository" config user.email 'tests@tailmox.invalid'
git -C "$TEST_DIR/repository" add .
git -C "$TEST_DIR/repository" commit -q -m 'initial release'

INSTALL_DIR="$TEST_DIR/opt/tailmox"
COMMAND_DIR="$TEST_DIR/usr-local-bin"
IDENTITY_FILE="$TEST_DIR/identity.txt"
STAGE_CALLS="$TEST_DIR/stage-calls"
printf 'existing identity\n' > "$IDENTITY_FILE"
export TAILMOX_STAGE_CALLS="$STAGE_CALLS"
OUTPUT=$(PATH="$TEST_DIR/bin:$PATH" \
    TAILMOX_FORCE_COLOR=true \
    TAILMOX_ALLOW_NON_ROOT=true \
    TAILMOX_REPOSITORY_URL="$TEST_DIR/repository" \
    TAILMOX_INSTALL_DIR="$INSTALL_DIR" \
    TAILMOX_BIN_DIR="$COMMAND_DIR" \
    TAILMOX_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    bash "$ROOT_DIR/install.sh")
PLAIN_OUTPUT=$(printf '%s' "$OUTPUT" | sed $'s/\e\\[[0-9;]*m//g')

[[ -x "$INSTALL_DIR/tailmox" ]]
[[ -x "$INSTALL_DIR/tailmox.sh" ]]
[[ -d "$INSTALL_DIR/.git" ]]
[[ "$(git -C "$INSTALL_DIR" branch --show-current)" == dev ]]
[[ "$(git -C "$INSTALL_DIR" remote get-url origin)" == "$TEST_DIR/repository" ]]
[[ -L "$COMMAND_DIR/tailmox" ]]
[[ "$(readlink "$COMMAND_DIR/tailmox")" == "$INSTALL_DIR/tailmox" ]]
grep -Fq $'\033[1;36m' <<< "$OUTPUT"
grep -Fq 'Run tailmox cluster when every host is ready.' <<< "$PLAIN_OUTPUT"
grep -Fq 'Node monitor     https://pve1.example.ts.net:8088/monitor/' <<< "$PLAIN_OUTPUT"
grep -Fq 'Service monitor  https://tailmox.example.ts.net/monitor/' <<< "$PLAIN_OUTPUT"
if grep -Fq 'tailmox.example.ts.net:8088' <<< "$PLAIN_OUTPUT"; then
    printf 'FAIL: shared service monitor URL includes the node monitor port\n'
    exit 1
fi
grep -Fxq 'stage' "$STAGE_CALLS"

printf 'new release marker\n' > "$TEST_DIR/repository/release-marker"
git -C "$TEST_DIR/repository" add release-marker
git -C "$TEST_DIR/repository" commit -q -m 'new release'
UPDATE_OUTPUT=$(PATH="$TEST_DIR/bin:$PATH" \
    TAILMOX_ALLOW_NON_ROOT=true \
    TAILMOX_REPOSITORY_URL="$TEST_DIR/repository" \
    TAILMOX_INSTALL_DIR="$INSTALL_DIR" \
    TAILMOX_BIN_DIR="$COMMAND_DIR" \
    TAILMOX_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    bash "$ROOT_DIR/install.sh")
grep -Fxq 'new release marker' "$INSTALL_DIR/release-marker"
grep -Fq 'Updated Tailmox from the dev branch.' <<< "$UPDATE_OUTPUT"

[[ "$(wc -l < "$STAGE_CALLS")" -eq 2 ]]

printf 'local change\n' >> "$INSTALL_DIR/tailmox.sh"
if DIRTY_OUTPUT=$(PATH="$TEST_DIR/bin:$PATH" \
    TAILMOX_ALLOW_NON_ROOT=true \
    TAILMOX_REPOSITORY_URL="$TEST_DIR/repository" \
    TAILMOX_INSTALL_DIR="$INSTALL_DIR" \
    TAILMOX_BIN_DIR="$COMMAND_DIR" \
    TAILMOX_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    bash "$ROOT_DIR/install.sh" 2>&1); then
    printf 'FAIL: installer updated a checkout with local changes\n'
    exit 1
fi
grep -Fq 'has local changes' <<< "$DIRTY_OUTPUT"
[[ "$(wc -l < "$STAGE_CALLS")" -eq 2 ]]

MIGRATION_DIR="$TEST_DIR/migration/opt/tailmox"
MIGRATION_BIN_DIR="$TEST_DIR/migration/usr-local-bin"
mkdir -p "$MIGRATION_DIR" "$MIGRATION_BIN_DIR"
cp "$TEST_DIR/repository/tailmox" "$TEST_DIR/repository/tailmox.sh" "$MIGRATION_DIR/"
ln -s "$MIGRATION_DIR/tailmox" "$MIGRATION_BIN_DIR/tailmox"
PATH="$TEST_DIR/bin:$PATH" \
    TAILMOX_ALLOW_NON_ROOT=true \
    TAILMOX_REPOSITORY_URL="$TEST_DIR/repository" \
    TAILMOX_INSTALL_DIR="$MIGRATION_DIR" \
    TAILMOX_BIN_DIR="$MIGRATION_BIN_DIR" \
    TAILMOX_AGE_IDENTITY_FILE="$IDENTITY_FILE" \
    bash "$ROOT_DIR/install.sh" >/dev/null
[[ -d "$MIGRATION_DIR/.git" ]]
[[ "$(git -C "$MIGRATION_DIR" branch --show-current)" == dev ]]
[[ "$(wc -l < "$STAGE_CALLS")" -eq 3 ]]

printf 'PASS: one-line installer clones, updates, migrates archive installs, stages, preserves identity, and rejects local changes\n'
