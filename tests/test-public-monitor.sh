#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$repo_root" <<'PY'
import json
import pathlib
import runpy
import tempfile
import time
import io
import sys

root = pathlib.Path(sys.argv[1])
private = runpy.run_path(str(root / "tailmox-monitor.py"))
status = {
    "generatedAt": int(time.time()), "overall": "healthy",
    "hostname": "secret-node", "services": {"corosync": {"active": True}, "pveCluster": {"active": True}},
    "cluster": {"quorate": "Yes", "name": "secret-cluster"},
    "corosync": {"members": [{"name": "secret-node", "ip": "100.64.0.1", "active": True}]},
    "tailscale": {"backendState": "Running", "self": {"DNSName": "secret.ts.net"}},
    "webservers": {"hosts": [{"name": "secret-node", "running": True}]},
    "influxdb": {"enabled": True, "online": True, "token": "secret-token"},
}
graph_sources = {
    "mtu": {"series": [{"name": "secret-node", "host": "secret-node", "samples": [{"timestamp": status["generatedAt"], "displayMtu": 1280, "configuredMtu": 0, "automatic": True, "hostname": "secret-node"}]}]},
    "members": {"series": [{"name": "secret-node", "samples": [{"timestamp": status["generatedAt"], "memberCount": 1, "configuredNodeCount": 1, "quorate": True, "ip": "100.64.0.1"}]}]},
    "linkQuality": {"series": [{"name": "secret-node to secret-peer", "peer": "secret-peer", "samples": [{"timestamp": status["generatedAt"], "avgMs": 1.2, "maxMs": 2.4, "jitterMs": 0.4, "packetLossPercent": 0, "hostname": "secret-peer"}]}]},
    "cmapKnet": {"series": [{"name": "secret-node to secret-peer", "nodeid": "9", "samples": [{"timestamp": status["generatedAt"], "latencyAvg": 12, "jitter": 2, "txPacketDelta": 10, "rxPacketDelta": 9, "errorDelta": 0, "raw": "secret-raw"}]}]},
    "tests": {"series": [{"name": "secret-node to secret-target", "target": "secret-target", "kind": "tailmox_icmp", "samples": [{"timestamp": status["generatedAt"], "avgMs": 3.2, "maxMs": 4.8, "received": 3, "sent": 3}]}]},
}
snapshot = private["public_snapshot"](status, {"links": [{
    "hostname": "secret-peer", "ip": "100.64.0.2", "nodeid": "9",
    "status": "joined", "quality": "good", "packetLossPercent": 0,
    "avgMs": 1.2, "maxMs": 2.4, "jitterMs": 0.4,
    "lastUpdatedAt": status["generatedAt"], "raw": "secret-raw-link",
}]}, graph_sources)
encoded = json.dumps(snapshot)
assert snapshot["schemaVersion"] == 4
assert snapshot["history"][-1] == {
    "timestamp": status["generatedAt"], "activeMembers": 1, "configuredMembers": 1,
    "healthyLinks": 1, "degradedLinks": 0, "offlineLinks": 0,
    "webOnline": 1, "webTotal": 1,
}
assert snapshot["graphs"]["mtu"]["series"][0]["name"] == "secret-node"
assert snapshot["graphs"]["linkQuality"]["series"][0]["name"] == "secret-node to secret-peer"
assert snapshot["graphs"]["tests"]["series"][0]["name"] == "secret-node to secret-target"
assert snapshot["graphs"]["tests"]["series"][0]["kind"] == "tailmox_icmp"
assert snapshot["linkQualityDetails"] == [{
    "hostname": "secret-peer", "status": "joined", "quality": "good",
    "packetLossPercent": 0, "avgMs": 1.2, "maxMs": 2.4, "jitterMs": 0.4,
    "lastUpdatedAt": status["generatedAt"],
}]
for visible in ("secret-node", "secret-peer", "secret-target"):
    assert visible in encoded, encoded
for secret in ("secret-raw", "secret-raw-link", "secret-cluster", "100.64.0.1", "100.64.0.2", "secret.ts.net", "secret-token"):
    assert secret not in encoded, encoded
for offset in range(1, 122):
    status["generatedAt"] += 30
    snapshot = private["public_snapshot"](status, {"links": [{"quality": "good"}]})
assert len(snapshot["history"]) == 120
assert len(json.dumps(snapshot).encode("utf-8")) < 2 * 1024 * 1024

public = runpy.run_path(str(root / "tailmox-public-monitor.py"))
with tempfile.TemporaryDirectory() as directory:
    snapshot_path = pathlib.Path(directory) / "status.json"
    snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
    handler = public["Handler"]
    handler.serve_snapshot.__globals__["SNAPSHOT_FILE"] = snapshot_path
    def request(method, path, host="tailmox.com"):
        instance = handler.__new__(handler)
        instance.command = method
        instance.path = path
        instance.headers = {"Host": host, "Tailscale-User-Login": "attacker@example.com"}
        instance.wfile = io.BytesIO()
        result = {"headers": {}}
        instance.send_response = lambda status: result.update(status=status)
        instance.send_header = lambda name, value: result["headers"].__setitem__(name, value)
        instance.end_headers = lambda: None
        getattr(instance, "do_" + method)()
        result["body"] = instance.wfile.getvalue()
        return result

    response = request("GET", "/")
    assert response["status"] == 200
    assert response["headers"]["X-Frame-Options"] == "DENY"
    assert response["headers"]["X-Content-Type-Options"] == "nosniff"
    assert "default-src 'none'" in response["headers"]["Content-Security-Policy"]
    assert b'id="members-chart"' in response["body"]
    assert b'id="mtu-chart"' in response["body"]
    assert b'id="link-quality-chart"' in response["body"]
    assert b'id="cmap-latency-chart"' in response["body"]
    assert b'id="cmap-packets-chart"' in response["body"]
    assert b'id="test-latency-chart"' in response["body"]
    assert b'<h1>tailmox</h1>' in response["body"]
    assert b'<h1>Tailmox Monitor</h1>' not in response["body"]
    assert b'public-monitor.css?v=9' in response["body"]
    assert b'public-monitor.js?v=8' in response["body"]
    assert b'id="link-quality-rows"' in response["body"]
    assert b'href="https://github.com/willjasen/tailmox"' in response["body"]
    assert b'aria-label="View tailmox on GitHub"' in response["body"]
    assert b'This public view includes graph history and hostnames.' in response["body"]
    assert b'Tailscale IP addresses' not in response["body"]
    assert b"googletagmanager" not in response["body"]
    assert request("GET", "/google-analytics.js")["status"] == 404
    assert response["headers"]["Strict-Transport-Security"] == "max-age=31536000"
    response = request("GET", "/snapshot.json")
    assert json.loads(response["body"]) == snapshot
    for path in ("/settings", "/api/status", "/api/actions", "/monitor"):
        assert request("GET", path)["status"] == 404, path
    assert request("POST", "/")["status"] == 405
    assert request("GET", "/", "evil.example")["status"] == 421

    handler.handle_read.__globals__["GA_MEASUREMENT_ID"] = "G-TEST123"
    response = request("GET", "/")
    assert b"https://www.googletagmanager.com/gtag/js?id=G-TEST123" in response["body"]
    assert "https://www.googletagmanager.com" in response["headers"]["Content-Security-Policy"]
    response = request("GET", "/google-analytics.js")
    assert response["status"] == 200
    assert b"G-TEST123" in response["body"]

unit = (root / "tailmox-public-monitor.service").read_text(encoding="utf-8")
for directive in (
    "User=tailmox-public", "NoNewPrivileges=yes", "ProtectSystem=strict",
    "CapabilityBoundingSet=", "IPAddressDeny=any", "IPAddressAllow=localhost",
    "EnvironmentFile=-/etc/tailmox/public-monitor.env",
):
    assert directive in unit, directive
export_drop_in = (root / "tailmox-public-monitor-export.conf").read_text(encoding="utf-8")
assert "TAILMOX_PUBLIC_SNAPSHOT_FILE=/run/tailmox-public-monitor/status.json" in export_drop_in
assert "RuntimeDirectory=tailmox-public-monitor" in export_drop_in
print("PASS: public monitor exposes only a sanitized, unprivileged read-only surface")
PY
