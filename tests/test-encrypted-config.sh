#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_BIN="$TEST_TMP/bin"
CLUSTER_DIR="$TEST_TMP/pve/tailmox"
mkdir -p "$MOCK_BIN" "$CLUSTER_DIR"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "-y" ]]; then' \
    '  if grep -q WRONG "${2:-}"; then printf "%s\n" age1wrongrecipient; else printf "%s\n" age1pq1tailmoxclusterrecipient; fi' \
    'else' \
    '  printf "%s\n" AGE-SECRET-KEY-PQ-1TAILMOXCLUSTERIDENTITY' \
    'fi' > "$MOCK_BIN/age-keygen"

printf '%s\n' \
    '#!/usr/bin/env python3' \
    'import base64' \
    'import sys' \
    'value = sys.stdin.buffer.read()' \
    'if sys.argv[1] == "--recipient":' \
    '    sys.stdout.buffer.write(b"age-encryption.org/v1\n" + base64.b64encode(value) + b"\n")' \
    'elif sys.argv[1] == "--decrypt":' \
    '    sys.stdout.buffer.write(base64.b64decode(value.splitlines()[1]))' \
    'else:' \
    '    raise SystemExit(2)' > "$MOCK_BIN/age"
chmod +x "$MOCK_BIN/age" "$MOCK_BIN/age-keygen"

common_env=(
    PYTHONPATH="$TEST_ROOT"
    TAILMOX_CONFIG_DIR="$CLUSTER_DIR"
    TAILMOX_PVE_CONFIG_DIR="$TEST_TMP/pve"
    TAILMOX_AGE_COMMAND="$MOCK_BIN/age"
    TAILMOX_AGE_KEYGEN_COMMAND="$MOCK_BIN/age-keygen"
)

env "${common_env[@]}" python3 - <<'PY'
from unittest import mock

import tailmox_config as config

target = config.CLUSTER_DIR / "pmxcfs-write-test.json"
with mock.patch.object(config.os, "fchmod", side_effect=PermissionError(1, "Operation not permitted")), \
     mock.patch.object(config.os, "chmod", side_effect=PermissionError(1, "Operation not permitted")):
    config.atomic_write(target, b'{"safe":true}\n', 0o644)
assert target.read_bytes() == b'{"safe":true}\n'
PY

RECOVERY_DIR="$TEST_TMP/recovery"
mkdir -p "$RECOVERY_DIR"
printf '%s\n' AGE-SECRET-KEY-PQ-1TAILMOXCLUSTERIDENTITY > "$RECOVERY_DIR/identity.txt"
env \
    PYTHONPATH="$TEST_ROOT" \
    TAILMOX_CONFIG_DIR="$RECOVERY_DIR/cluster" \
    TAILMOX_PVE_CONFIG_DIR="$RECOVERY_DIR/pve" \
    TAILMOX_AGE_COMMAND="$MOCK_BIN/age" \
    TAILMOX_AGE_KEYGEN_COMMAND="$MOCK_BIN/age-keygen" \
    TAILMOX_AGE_IDENTITY_FILE="$RECOVERY_DIR/identity.txt" \
    python3 - <<'PY'
import tailmox_config as config

recovered = config.create_identity()
assert recovered["identity"] == "AGE-SECRET-KEY-PQ-1TAILMOXCLUSTERIDENTITY"
assert recovered["recipient"] == "age1pq1tailmoxclusterrecipient"
assert config.security_document()["ageRecipient"] == recovered["recipient"]
PY

env "${common_env[@]}" \
    TAILMOX_HOSTNAME=pve1 \
    TAILMOX_AGE_IDENTITY_FILE="$TEST_TMP/pve1/identity.txt" \
    TAILMOX_SIGNING_KEY_FILE="$TEST_TMP/pve1/signing-key.pem" \
    python3 - <<'PY'
import tailmox_config as config

created = config.create_identity()
assert created["identity"].startswith("AGE-SECRET-KEY-PQ-1")
assert created["recipient"].startswith("age1pq1")
config.enroll_local_host()
proposal = config.propose_config(
    {
        "schemaVersion": 1,
        "influxdb": {
            "url": "https://influx.example",
            "token": "initial-secret",
            "org": "lab",
            "bucket": "metrics",
        },
    },
    "Initial encrypted configuration",
)
assert proposal["activated"] is True
PY

env "${common_env[@]}" \
    TAILMOX_HOSTNAME=pve2 \
    TAILMOX_AGE_IDENTITY_FILE="$TEST_TMP/pve2/identity.txt" \
    TAILMOX_SIGNING_KEY_FILE="$TEST_TMP/pve2/signing-key.pem" \
    python3 - <<'PY'
import tailmox_config as config

config.install_identity("AGE-SECRET-KEY-PQ-1TAILMOXCLUSTERIDENTITY")
config.enroll_local_host()
assert config.current_config()["influxdb"]["token"] == "initial-secret"
try:
    config.install_identity("AGE-SECRET-KEY-1WRONGIDENTITY")
except config.ConfigError:
    pass
else:
    raise AssertionError("a mismatched cluster identity was accepted")
assert config.IDENTITY_FILE.read_text().strip() == "AGE-SECRET-KEY-PQ-1TAILMOXCLUSTERIDENTITY"
PY

PROPOSAL_ID=$(
    env "${common_env[@]}" \
        TAILMOX_HOSTNAME=pve1 \
        TAILMOX_AGE_IDENTITY_FILE="$TEST_TMP/pve1/identity.txt" \
        TAILMOX_SIGNING_KEY_FILE="$TEST_TMP/pve1/signing-key.pem" \
        python3 - <<'PY'
import tailmox_config as config

document = config.current_config()
document["influxdb"]["token"] = "replacement-secret"
proposal = config.propose_config(document, "Rotate the InfluxDB token")
assert proposal["activated"] is False
assert proposal["receipts"] == {"pve1": "accepted", "pve2": None}
print(proposal["proposalId"])
PY
)

env "${common_env[@]}" \
    TAILMOX_HOSTNAME=pve2 \
    TAILMOX_AGE_IDENTITY_FILE="$TEST_TMP/pve2/identity.txt" \
    TAILMOX_SIGNING_KEY_FILE="$TEST_TMP/pve2/signing-key.pem" \
    PROPOSAL_ID="$PROPOSAL_ID" \
    python3 - <<'PY'
import os
import tailmox_config as config

accepted = config.decide_proposal(os.environ["PROPOSAL_ID"], "accepted")
assert accepted["activated"] is True
assert config.current_config()["influxdb"]["token"] == "replacement-secret"
approved_ciphertext = config.CONFIG_FILE.read_bytes()
tampered = config.current_config()
tampered["revision"] = 3
tampered["influxdb"]["token"] = "unsigned-secret"
config.atomic_write(config.CONFIG_FILE, config.encrypt_config(tampered), 0o644)
try:
    config.current_config()
except config.ConfigError:
    pass
else:
    raise AssertionError("an encrypted but unsigned configuration was accepted")
config.atomic_write(config.CONFIG_FILE, approved_ciphertext, 0o644)
PY

if grep -R -Fq 'replacement-secret' "$CLUSTER_DIR"; then
    printf 'FAIL: plaintext credentials were written to the clustered filesystem\n'
    exit 1
fi
if cmp -s "$TEST_TMP/pve1/signing-key.pem" "$TEST_TMP/pve2/signing-key.pem"; then
    printf 'FAIL: hosts reused the same Tailmox signing key\n'
    exit 1
fi
if grep -Fq 'PRIVATE KEY' "$CLUSTER_DIR/security.json"; then
    printf 'FAIL: a private host signing key entered the clustered filesystem\n'
    exit 1
fi
if [[ "$(stat -c '%a' "$TEST_TMP/pve1/signing-key.pem" 2>/dev/null || stat -f '%Lp' "$TEST_TMP/pve1/signing-key.pem")" != "600" ]]; then
    printf 'FAIL: the host signing key is not private\n'
    exit 1
fi

printf 'PASS: shared age encryption and dedicated Ed25519 host approvals protect Tailmox configuration\n'
