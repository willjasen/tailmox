#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

ROOT_DIR="$ROOT_DIR" \
TAILMOX_CONFIG_FILE="$TEST_DIR/config.age" \
TAILMOX_IDENTITY_FILE="$TEST_DIR/identity.txt" \
TAILMOX_LEGACY_CONFIG_FILE="$TEST_DIR/tailmox.conf" \
TAILMOX_INFLUXDB_ENV_FILE="$TEST_DIR/monitor.env" \
python3 - <<'PY'
import os
import runpy

module = runpy.run_path(os.path.join(os.environ["ROOT_DIR"], "tailmox-monitor.py"))
captured = {}
function_globals = module["influx_test_history"].__globals__
function_globals["influx_config"] = lambda: {"bucket": "metrics"}
function_globals["socket"].gethostname = lambda: "node1.example.test"

def query(flux, timeout=8):
    captured["flux"] = flux
    return []

function_globals["influx_query"] = query
assert module["influx_test_history"]() == []
assert 'r.host == "node1.example.test"' in captured["flux"]
assert 'r.host == "node1"' in captured["flux"]
assert " or " in captured["flux"]
PY

grep -Fq 'hostname=$(hostname)' "$ROOT_DIR/tailmox-influx-export.sh"

printf 'InfluxDB test history hostname tests passed\n'
