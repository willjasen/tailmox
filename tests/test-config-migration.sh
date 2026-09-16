#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

printf '%s\n' \
    'TAILMOX_INFLUXDB_URL=https://legacy.example.test' \
    'TAILMOX_INFLUXDB_TOKEN=migration-test-token' \
    'TAILMOX_INFLUXDB_ORG=legacy-org' \
    'TAILMOX_INFLUXDB_BUCKET=legacy-bucket' > "$TEST_DIR/tailmox.conf"

ROOT_DIR="$ROOT_DIR" TEST_DIR="$TEST_DIR" \
TAILMOX_LEGACY_CONFIG_FILE="$TEST_DIR/tailmox.conf" \
TAILMOX_INFLUXDB_ENV_FILE="$TEST_DIR/monitor.env" \
TAILMOX_CONFIG_FILE="$TEST_DIR/config.age" \
TAILMOX_IDENTITY_FILE="$TEST_DIR/identity.txt" \
python3 - <<'PY'
import os
import pathlib
import runpy

module = runpy.run_path(os.path.join(os.environ["ROOT_DIR"], "tailmox-monitor.py"))
legacy_path = pathlib.Path(os.environ["TEST_DIR"]) / "tailmox.conf"

# Existing installations keep exporting from plaintext until activation.
values = module["influx_config"]()
assert values == {
    "url": "https://legacy.example.test",
    "token": "migration-test-token",
    "org": "legacy-org",
    "bucket": "legacy-bucket",
}

config_module = module["tailmox_config"]
config_module.enroll_local_host = lambda: None
config_module.list_proposals = lambda: []
config_module.current_config = lambda: {
    "schemaVersion": 1,
    "revision": 0,
    "influxdb": {"url": "", "token": "", "org": "", "bucket": ""},
}
captured = {}
def pending(document, summary):
    captured["document"] = document
    captured["summary"] = summary
    return {"proposalId": "1-test", "activated": False}
config_module.propose_config = pending

result = module["initialize_encrypted_configuration"]({"created": True})
assert result["migrationProposal"]["activated"] is False
assert captured["document"]["influxdb"]["token"] == "migration-test-token"
assert "plaintext Tailmox configuration" in captured["summary"]
assert legacy_path.is_file(), "plaintext was removed before approval"

config_module.propose_config = lambda document, summary: {
    "proposalId": "1-test", "activated": True
}
module["initialize_encrypted_configuration"]({"created": True})
assert not legacy_path.exists(), "plaintext was retained after activation"
PY

printf 'config migration tests passed\n'
