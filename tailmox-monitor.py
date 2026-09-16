#!/usr/bin/env python3
"""
Tailmox monitoring interface.

Runs a small localhost-only HTTP server that reports Proxmox, Tailscale, and
corosync health for the current node.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import socket
import subprocess
import time
from urllib.parse import urlparse


HOST = os.environ.get("TAILMOX_MONITOR_HOST", "127.0.0.1")
PORT = int(os.environ.get("TAILMOX_MONITOR_PORT", "8088"))


def run_command(command, timeout=5):
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
        }
    except FileNotFoundError:
        return {"ok": False, "returncode": 127, "stdout": "", "stderr": f"{command[0]} not found"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "returncode": 124, "stdout": "", "stderr": "command timed out"}


def parse_pvecm_status(output):
    fields = {}
    for line in output.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip().lower().replace(" ", "_")] = value.strip()
    return fields


def parse_quorum(output):
    nodes = []
    in_nodes = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Nodeid"):
            in_nodes = True
            continue
        if not in_nodes or not stripped or stripped.startswith("-"):
            continue
        parts = stripped.split()
        if len(parts) >= 3 and parts[0].isdigit():
            nodes.append(
                {
                    "nodeid": parts[0],
                    "votes": parts[1],
                    "name": parts[-1],
                    "local": "(local)" in stripped,
                }
            )
    return nodes


def parse_corosync_members(output):
    members = []
    current = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Nodeid:"):
            if current:
                members.append(current)
            current = {"nodeid": stripped.split(":", 1)[1].strip()}
        elif current and stripped.startswith("Name:"):
            current["name"] = stripped.split(":", 1)[1].strip()
        elif current and stripped.startswith("Status:"):
            current["status"] = stripped.split(":", 1)[1].strip()
    if current:
        members.append(current)
    return members


def collect_status():
    service = run_command(["systemctl", "is-active", "corosync"])
    enabled = run_command(["systemctl", "is-enabled", "corosync"])
    pve_cluster = run_command(["systemctl", "is-active", "pve-cluster"])
    pvecm = run_command(["pvecm", "status"])
    quorum = run_command(["corosync-quorumtool", "-s"])
    members = run_command(["corosync-cmapctl", "runtime.members"])
    tailscale = run_command(["tailscale", "status", "--json"])
    journal = run_command(["journalctl", "-u", "corosync", "-n", "25", "--no-pager"], timeout=8)

    pvecm_fields = parse_pvecm_status(pvecm["stdout"]) if pvecm["stdout"] else {}
    quorum_nodes = parse_quorum(quorum["stdout"]) if quorum["stdout"] else []
    corosync_members = parse_corosync_members(members["stdout"]) if members["stdout"] else []

    tailscale_data = {}
    if tailscale["stdout"]:
        try:
            tailscale_data = json.loads(tailscale["stdout"])
        except json.JSONDecodeError:
            tailscale_data = {}

    expected_votes = pvecm_fields.get("expected_votes")
    total_votes = pvecm_fields.get("total_votes")
    quorate = pvecm_fields.get("quorate")
    corosync_active = service["stdout"] == "active"
    pve_cluster_active = pve_cluster["stdout"] == "active"
    healthy = corosync_active and pve_cluster_active and quorate == "Yes"

    return {
        "generatedAt": int(time.time()),
        "hostname": socket.gethostname(),
        "overall": "healthy" if healthy else "attention",
        "services": {
            "corosync": {
                "active": corosync_active,
                "enabled": enabled["stdout"],
                "detail": service["stderr"] or service["stdout"],
            },
            "pveCluster": {
                "active": pve_cluster_active,
                "detail": pve_cluster["stderr"] or pve_cluster["stdout"],
            },
        },
        "cluster": {
            "name": pvecm_fields.get("name"),
            "configVersion": pvecm_fields.get("config_version"),
            "transport": pvecm_fields.get("transport"),
            "secureAuth": pvecm_fields.get("secure_auth"),
            "quorate": quorate,
            "expectedVotes": expected_votes,
            "totalVotes": total_votes,
            "highestExpected": pvecm_fields.get("highest_expected"),
        },
        "corosync": {
            "members": corosync_members,
            "quorumNodes": quorum_nodes,
            "rawStatus": pvecm["stdout"],
            "rawQuorum": quorum["stdout"],
            "recentLogs": journal["stdout"].splitlines()[-25:] if journal["stdout"] else [],
            "errors": [
                item["stderr"]
                for item in [pvecm, quorum, members, journal]
                if item["stderr"] and item["returncode"] not in (0, 1)
            ],
        },
        "tailscale": {
            "self": tailscale_data.get("Self", {}),
            "backendState": tailscale_data.get("BackendState"),
        },
    }


INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tailmox Monitor</title>
  <style>
    :root { color-scheme: light dark; --bg: #0f172a; --panel: #111827; --line: #334155; --text: #e5e7eb; --muted: #94a3b8; --good: #22c55e; --warn: #f59e0b; --bad: #ef4444; --accent: #38bdf8; }
    body { margin: 0; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); }
    main { max-width: 1180px; margin: 0 auto; padding: 28px; }
    header { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; margin-bottom: 24px; }
    h1 { font-size: 28px; margin: 0 0 6px; }
    h2 { font-size: 15px; margin: 0 0 14px; color: var(--muted); font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; }
    .muted { color: var(--muted); }
    .grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 14px; }
    .wide { grid-column: span 2; }
    .full { grid-column: 1 / -1; }
    .panel { border: 1px solid var(--line); border-radius: 8px; padding: 16px; background: var(--panel); }
    .metric { font-size: 28px; font-weight: 750; }
    .pill { display: inline-flex; align-items: center; gap: 7px; border: 1px solid var(--line); border-radius: 999px; padding: 6px 10px; font-size: 13px; }
    .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--bad); }
    .ok .dot { background: var(--good); }
    .warn .dot { background: var(--warn); }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 9px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-size: 13px; font-weight: 600; }
    pre { white-space: pre-wrap; overflow: auto; margin: 0; color: #cbd5e1; font-size: 13px; line-height: 1.45; }
    a { color: var(--accent); }
    @media (max-width: 850px) { main { padding: 18px; } header { display: block; } .grid { grid-template-columns: 1fr; } .wide { grid-column: auto; } }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Tailmox Monitor</h1>
        <div class="muted" id="subtitle">Loading cluster health...</div>
      </div>
      <div class="pill" id="overall"><span class="dot"></span><span>Loading</span></div>
    </header>
    <section class="grid">
      <div class="panel"><h2>Corosync</h2><div class="metric" id="corosyncState">...</div><div class="muted" id="corosyncEnabled"></div></div>
      <div class="panel"><h2>Quorum</h2><div class="metric" id="quorumState">...</div><div class="muted" id="votes"></div></div>
      <div class="panel"><h2>Cluster</h2><div class="metric" id="clusterName">...</div><div class="muted" id="transport"></div></div>
      <div class="panel"><h2>Tailscale</h2><div class="metric" id="tailscaleState">...</div><div class="muted" id="tailscaleName"></div></div>
      <div class="panel wide"><h2>Corosync Members</h2><table><thead><tr><th>Node</th><th>ID</th><th>Status</th></tr></thead><tbody id="members"></tbody></table></div>
      <div class="panel wide"><h2>Quorum Nodes</h2><table><thead><tr><th>Node</th><th>ID</th><th>Votes</th><th>Local</th></tr></thead><tbody id="quorumNodes"></tbody></table></div>
      <div class="panel full"><h2>Recent Corosync Logs</h2><pre id="logs">Loading...</pre></div>
      <div class="panel full"><h2>Raw Cluster Status</h2><pre id="raw"></pre></div>
    </section>
  </main>
  <script>
    const text = (id, value) => document.getElementById(id).textContent = value || "unknown";
    const yesNo = value => value ? "active" : "inactive";
    async function refresh() {
      const response = await fetch("/api/status", { cache: "no-store" });
      const data = await response.json();
      document.getElementById("subtitle").textContent = `${data.hostname} refreshed ${new Date(data.generatedAt * 1000).toLocaleString()}`;
      const overall = document.getElementById("overall");
      overall.className = `pill ${data.overall === "healthy" ? "ok" : "warn"}`;
      overall.lastElementChild.textContent = data.overall === "healthy" ? "Healthy" : "Needs attention";
      text("corosyncState", yesNo(data.services.corosync.active));
      text("corosyncEnabled", `enabled: ${data.services.corosync.enabled || "unknown"}`);
      text("quorumState", data.cluster.quorate === "Yes" ? "quorate" : "not quorate");
      text("votes", `${data.cluster.totalVotes || "?"} of ${data.cluster.expectedVotes || "?"} expected votes`);
      text("clusterName", data.cluster.name || "none");
      text("transport", `transport: ${data.cluster.transport || "unknown"}`);
      text("tailscaleState", data.tailscale.backendState || "unknown");
      text("tailscaleName", data.tailscale.self.DNSName || data.tailscale.self.HostName || "");
      document.getElementById("members").innerHTML = (data.corosync.members || []).map(member => `<tr><td>${member.name || ""}</td><td>${member.nodeid || ""}</td><td>${member.status || ""}</td></tr>`).join("") || "<tr><td colspan='3'>No member data available</td></tr>";
      document.getElementById("quorumNodes").innerHTML = (data.corosync.quorumNodes || []).map(node => `<tr><td>${node.name || ""}</td><td>${node.nodeid || ""}</td><td>${node.votes || ""}</td><td>${node.local ? "yes" : ""}</td></tr>`).join("") || "<tr><td colspan='4'>No quorum node data available</td></tr>";
      text("logs", (data.corosync.recentLogs || []).join("\\n") || "No recent corosync logs available.");
      text("raw", data.corosync.rawStatus || "No pvecm status output available.");
    }
    refresh();
    setInterval(refresh, 15000);
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def send_body(self, status, content_type, body):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self.send_body(200, "text/html; charset=utf-8", INDEX_HTML)
        elif path == "/api/status":
            self.send_body(200, "application/json", json.dumps(collect_status()))
        else:
            self.send_body(404, "text/plain; charset=utf-8", "not found")

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Tailmox monitor listening on http://{HOST}:{PORT}")
    server.serve_forever()
