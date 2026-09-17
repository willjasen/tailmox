#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$ROOT_DIR" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import os
import runpy
from unittest.mock import patch

module = runpy.run_path(os.path.join(os.environ["ROOT_DIR"], "tailmox-monitor.py"))
nodes = [
    {"nodeid": "1", "name": "pve1", "ring0_addr": "100.64.0.1"},
    {"nodeid": "2", "name": "pve2", "ring0_addr": "100.64.0.2"},
    {"nodeid": "3", "name": "pve3"},
]

class Connection:
    def close(self):
        pass

def connect(address, timeout):
    assert address[1] == 8088
    assert timeout == module["WEBSERVER_CHECK_TIMEOUT_SECONDS"]
    if address[0] == "100.64.0.2":
        raise ConnectionRefusedError("connection refused")
    return Connection()

with patch.object(module["socket"], "create_connection", side_effect=connect):
    result = module["collect_webserver_health"](nodes)

assert result["port"] == 8088
assert [host["name"] for host in result["hosts"] if host["running"]] == ["pve1"]
assert [host["name"] for host in result["offlineHosts"]] == ["pve2", "pve3"]
assert "not running the port ${data.webservers?.port||8088} webserver" in module["HEALTH_HTML"]
assert "missingWebservers.map(host=>host.name" in module["HEALTH_HTML"]
assert 'add("Tailmox webservers are online"' in module["HEALTH_HTML"]
assert 'add("Corosync is online"' in module["HEALTH_HTML"]
assert 'add("Proxmox cluster service is online"' in module["HEALTH_HTML"]
assert 'add("All cluster hosts are online"' in module["HEALTH_HTML"]
assert 'add("Cluster has quorum"' in module["HEALTH_HTML"]
assert 'add(`Link to ${peer} is healthy`' in module["HEALTH_HTML"]
assert 'issues.querySelector(".check:not(.pass)")' in module["HEALTH_HTML"]
PY

printf 'PASS: health page identifies hosts without the port 8088 webserver\n'
