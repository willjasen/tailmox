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
captured = []
function_globals = module["influx_test_history"].__globals__
function_globals["influx_config"] = lambda: {"bucket": "metrics"}
function_globals["collect_corosync_members"] = lambda: []
function_globals["collect_configured_nodes"] = lambda: []

def query(flux, timeout=8):
    captured.append(flux)
    return []

function_globals["influx_query"] = query
for name in (
    "influx_mtu_history",
    "influx_test_history",
    "influx_link_quality_history",
    "influx_member_count_history",
    "influx_cmap_knet_history",
):
    assert module[name]() == []

assert len(captured) == 5
assert all('r.host ==' not in flux for flux in captured)
assert all("range(start: -1h)" in flux for flux in captured)
assert all("aggregateWindow(every: 1m, fn: last, createEmpty: false)" in flux for flux in captured)

function_globals["influx_query"] = lambda flux, timeout=8: [
    {"_time": "2026-09-17T01:00:00Z", "_measurement": "tailmox_icmp", "_field": "average_ms", "_value": "1.5", "host": "pve3", "node": "pve4"},
    {"_time": "2026-09-17T01:00:00Z", "_measurement": "tailmox_icmp", "_field": "average_ms", "_value": "2.5", "host": "pve4", "node": "pve3"},
]
series = module["influx_test_history"]()
assert [item["name"] for item in series] == ["pve3 → pve4", "pve4 → pve3"]
assert [item["host"] for item in series] == ["pve3", "pve4"]
PY

grep -Fq 'hostname=$(hostname)' "$ROOT_DIR/tailmox-influx-export.sh"
grep -Fq '"$TAILMOX_ROOT/tailmox" check' "$ROOT_DIR/tailmox-influx-export.sh"
grep -Fq 'run_command([test_command, "check"]' "$ROOT_DIR/tailmox-monitor"
[[ "$(grep -Fc 'range(start: -1h)' "$ROOT_DIR/tailmox-monitor.py")" -eq 5 ]]
[[ "$(grep -Fc 'aggregateWindow(every: 1m, fn: last, createEmpty: false)' "$ROOT_DIR/tailmox-monitor.py")" -eq 5 ]]

printf 'InfluxDB all-host history tests passed\n'
