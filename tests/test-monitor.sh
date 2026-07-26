#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

MOCK_TAILMOX="$TEST_TMP/tailmox"
MOCK_TAILSCALE="$TEST_TMP/tailscale"
MOCK_PVECM="$TEST_TMP/pvecm"
DATABASE="$TEST_TMP/monitor.sqlite3"
WEB_OUTPUT="$TEST_TMP/web/monitor.json"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "${1:-}" == "test" ]] || exit 2' \
    'printf "%s\n" " - pve-local (pve-local.example.ts.net)"' \
    'printf "%s\n" "   - Tailscale path: 20 of 20 Tailscale pings succeeded (80% required)."' \
    'printf "%s\n" "   - 64-byte ICMP: average latency 1.25 ms; maximum latency 2.50 ms; all replies arrived within 50 ms; 0% packet loss."' \
    'printf "%s\n" "   - TCP port 8006 is available."' \
    'printf "%s\n" " - pve-remote (100.64.0.2)"' \
    'printf "%s\n" "   - TCP port 443 is not available."' \
    'exit 1' > "$MOCK_TAILMOX"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "${1:-}" == "status" && "${2:-}" == "--json" ]] || exit 2' \
    'printf "%s\n" '"'"'{"BackendState":"Running","Self":{"HostName":"pve-local","DNSName":"pve-local.example.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true,"Tags":["tag:tailmox"]},"Peer":{"remote":{"HostName":"pve-remote","DNSName":"pve-remote.example.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":true,"Tags":["tag:tailmox"]}}}'"'" \
    > "$MOCK_TAILSCALE"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "Cluster information" "-------------------" "Name: lab-cluster" "Nodes: 2" "Expected votes: 2" "Total votes: 2" "Quorum: 2" "Quorate: Yes" "Ring ID: 1.2a"' \
    > "$MOCK_PVECM"

chmod +x "$MOCK_TAILMOX" "$MOCK_TAILSCALE" "$MOCK_PVECM"

TAILMOX_MONITOR_DB="$DATABASE" \
TAILMOX_MONITOR_WEB_OUTPUT="$WEB_OUTPUT" \
TAILMOX_MONITOR_TEST_COMMAND="$MOCK_TAILMOX" \
TAILMOX_MONITOR_TAILSCALE_COMMAND="$MOCK_TAILSCALE" \
TAILMOX_MONITOR_PVECM_COMMAND="$MOCK_PVECM" \
TAILMOX_MONITOR_SSE_ENABLED=false \
    "$TEST_ROOT/tailmox-monitor" --mode cluster --once >/dev/null

python3 - "$DATABASE" "$WEB_OUTPUT" <<'PY'
import json
import sqlite3
import sys

database, web_output = sys.argv[1:]
connection = sqlite3.connect(database)

run = connection.execute(
    "SELECT mode, cluster_name, status, test_exit_code FROM monitor_runs"
).fetchone()
assert run == ("cluster", "lab-cluster", "failed", 1), run

nodes = connection.execute(
    "SELECT COUNT(*) FROM monitor_run_nodes"
).fetchone()[0]
assert nodes == 2, nodes

checks = connection.execute(
    """
    SELECT category, status, port, packet_size_bytes, latency_maximum_ms
    FROM monitor_checks
    ORDER BY id
    """
).fetchall()
assert len(checks) == 5, checks
assert ("tcp", "failed", 443, None, None) in checks, checks
assert ("icmp", "passed", None, 64, 2.5) in checks, checks

cluster = connection.execute(
    """
    SELECT quorate, configured_nodes, expected_votes, total_votes, quorum, ring_id
    FROM monitor_cluster_samples
    """
).fetchone()
assert cluster == (1, 2, 2, 2, 2, "1.2a"), cluster

columns = {
    row[1]
    for table in ("monitor_runs", "monitor_nodes", "monitor_checks", "monitor_cluster_samples")
    for row in connection.execute(f"PRAGMA table_info({table})")
}
assert not {"json", "payload", "raw_output"} & columns, columns

with open(web_output, encoding="utf-8") as source:
    analytics = json.load(source)
assert analytics["latest"]["mode"] == "cluster", analytics
assert analytics["latest"]["clusterName"] == "lab-cluster", analytics
assert analytics["latest"]["cluster"]["quorate"] is True, analytics
assert analytics["last24Hours"]["failed"] == 1, analytics
assert len(analytics["latest"]["nodes"]) == 2, analytics
assert len(analytics["latest"]["issues"]) == 1, analytics
PY

if grep -aFq '"BackendState"' "$DATABASE"; then
    printf 'FAIL: raw Tailscale JSON was stored in SQLite\n'
    exit 1
fi

if ! grep -Fq '"Content-Type", "text/event-stream"' "$TEST_ROOT/tailmox-monitor" ||
    grep -Fq 'def do_POST' "$TEST_ROOT/tailmox-monitor"; then
    printf 'FAIL: monitor event endpoint is missing or accepts uploaded results\n'
    exit 1
fi

printf 'PASS: monitor stores normalized analytics and exposes read-only SSE\n'

PRE_CLUSTER_DATABASE="$TEST_TMP/pre-cluster.sqlite3"
TAILMOX_MONITOR_DB="$PRE_CLUSTER_DATABASE" \
TAILMOX_MONITOR_WEB_OUTPUT="$TEST_TMP/web/pre-cluster.json" \
TAILMOX_MONITOR_TEST_COMMAND="$MOCK_TAILMOX" \
TAILMOX_MONITOR_TAILSCALE_COMMAND="$MOCK_TAILSCALE" \
TAILMOX_MONITOR_PVECM_COMMAND="$TEST_TMP/pvecm-must-not-run" \
TAILMOX_MONITOR_SSE_ENABLED=false \
    "$TEST_ROOT/tailmox-monitor" --mode pre-cluster --once >/dev/null

python3 - "$PRE_CLUSTER_DATABASE" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
mode = connection.execute("SELECT mode FROM monitor_runs").fetchone()[0]
cluster_samples = connection.execute(
    "SELECT COUNT(*) FROM monitor_cluster_samples"
).fetchone()[0]
assert mode == "pre-cluster", mode
assert cluster_samples == 0, cluster_samples
PY

printf 'PASS: pre-cluster mode omits cluster-only collection\n'

AUTO_DATABASE="$TEST_TMP/auto.sqlite3"
TAILMOX_MONITOR_DB="$AUTO_DATABASE" \
TAILMOX_MONITOR_WEB_OUTPUT="$TEST_TMP/web/auto.json" \
TAILMOX_MONITOR_TEST_COMMAND="$MOCK_TAILMOX" \
TAILMOX_MONITOR_TAILSCALE_COMMAND="$MOCK_TAILSCALE" \
TAILMOX_MONITOR_PVECM_COMMAND="$MOCK_PVECM" \
TAILMOX_MONITOR_SSE_ENABLED=false \
    "$TEST_ROOT/tailmox-monitor" --mode auto --once >/dev/null

python3 - "$AUTO_DATABASE" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
requested_mode, mode, cluster_name = connection.execute(
    "SELECT requested_mode, mode, cluster_name FROM monitor_runs"
).fetchone()
assert (requested_mode, mode, cluster_name) == (
    "auto",
    "cluster",
    "lab-cluster",
), (requested_mode, mode, cluster_name)
PY

printf 'PASS: auto mode activates cluster collection after membership detection\n'
