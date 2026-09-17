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
grep -Fq 'tailmox_corosync_link_quality,host=%s,peer_host=%s' "$ROOT_DIR/tailmox-influx-export.sh"
grep -Fq 'TAILMOX_INFLUX_RUN_ONCE' "$ROOT_DIR/tailmox-influx-export.sh"
grep -Fq 'run_command([test_command, "check"]' "$ROOT_DIR/tailmox-monitor"
[[ "$(grep -Fc 'range(start: -1h)' "$ROOT_DIR/tailmox-monitor.py")" -eq 5 ]]
[[ "$(grep -Fc 'aggregateWindow(every: 1m, fn: last, createEmpty: false)' "$ROOT_DIR/tailmox-monitor.py")" -eq 5 ]]

mkdir -p "$TEST_DIR/exporter/bin" "$TEST_DIR/exporter/root"
cp "$ROOT_DIR/tailmox-influx-export.sh" "$TEST_DIR/exporter/root/"
cat > "$TEST_DIR/exporter/root/tailmox" <<'SH'
#!/usr/bin/env bash
printf '__TAILMOX_MONITOR_ICMP__\tpve3\t64\tpassed\t15\t15\t1.25\t2.50\t5\n'
printf '__TAILMOX_MONITOR_ICMP__\tpve3\t1280\tpassed\t15\t15\t1.50\t2.75\t5\n'
printf '__TAILMOX_MONITOR_ICMP__\tpve4\t64\twarning\t12\t15\t3.00\t7.00\t6\n'
printf '__TAILMOX_MONITOR_ICMP__\tpve5\t64\tfailed\tunknown\tunknown\tunknown\tunknown\t7\n'
SH
cat > "$TEST_DIR/exporter/bin/corosync-cmapctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TEST_DIR/exporter/bin/curl" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
    if [[ "$argument" == @* ]]; then
        cp "${argument#@}" "$TAILMOX_CAPTURE_FILE"
        exit 0
    fi
done
exit 1
SH
chmod +x "$TEST_DIR/exporter/root/tailmox" "$TEST_DIR/exporter/bin/corosync-cmapctl" "$TEST_DIR/exporter/bin/curl"
cat > "$TEST_DIR/exporter/influx.env" <<'EOF'
TAILMOX_INFLUXDB_URL=https://influx.example.test
TAILMOX_INFLUXDB_TOKEN=test-token
TAILMOX_INFLUXDB_ORG=test-org
TAILMOX_INFLUXDB_BUCKET=test-bucket
EOF
PATH="$TEST_DIR/exporter/bin:$PATH" \
TAILMOX_INFLUX_ENV_FILE="$TEST_DIR/exporter/influx.env" \
TAILMOX_INFLUX_RUN_ONCE=true \
TAILMOX_CAPTURE_FILE="$TEST_DIR/exporter/payload" \
bash "$TEST_DIR/exporter/root/tailmox-influx-export.sh"
grep -Eq '^tailmox_corosync_link_quality,host=[^,]+,peer_host=pve3 packet_loss_percent=0[.]000000,avg_ms=1[.]25,max_ms=2[.]50 ' "$TEST_DIR/exporter/payload"
grep -Eq '^tailmox_corosync_link_quality,host=[^,]+,peer_host=pve4 packet_loss_percent=20[.]000000,avg_ms=3[.]00,max_ms=7[.]00 ' "$TEST_DIR/exporter/payload"
[[ "$(grep -c 'tailmox_corosync_link_quality.*peer_host=pve3' "$TEST_DIR/exporter/payload")" -eq 1 ]]
! grep -q 'tailmox_corosync_link_quality.*peer_host=pve5' "$TEST_DIR/exporter/payload"

printf 'InfluxDB all-host history tests passed\n'
