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
import re
import urllib.error
import urllib.parse
import urllib.request
import secrets
from urllib.parse import urlparse


HOST = os.environ.get("TAILMOX_MONITOR_HOST", "127.0.0.1")
PORT = int(os.environ.get("TAILMOX_MONITOR_PORT", "8088"))
INFLUX_ENV_FILE = os.environ.get("TAILMOX_INFLUXDB_ENV_FILE", "/etc/tailmox-monitor.env")
LINK_QUALITY_TTL_SECONDS = 30
LINK_QUALITY_CACHE = {"generatedAt": 0, "links": []}
INFLUX_STATE = {"lastWriteAt": None, "lastError": None}
CSRF_TOKEN = secrets.token_urlsafe(32)


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


def influx_config():
    return {
        "url": os.environ.get("TAILMOX_INFLUXDB_URL", "").rstrip("/"),
        "token": os.environ.get("TAILMOX_INFLUXDB_TOKEN", ""),
        "org": os.environ.get("TAILMOX_INFLUXDB_ORG", ""),
        "bucket": os.environ.get("TAILMOX_INFLUXDB_BUCKET", ""),
    }


def read_influx_env_file():
    config = {}
    try:
        with open(INFLUX_ENV_FILE, "r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or "=" not in stripped:
                    continue
                key, value = stripped.split("=", 1)
                config[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return config


def shell_quote_env(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def save_influx_config(data):
    current = read_influx_env_file()
    token = str(data.get("token", "")).strip()
    if not token:
        token = current.get("TAILMOX_INFLUXDB_TOKEN", os.environ.get("TAILMOX_INFLUXDB_TOKEN", ""))

    next_config = {
        "TAILMOX_INFLUXDB_URL": str(data.get("url", "")).strip().rstrip("/"),
        "TAILMOX_INFLUXDB_TOKEN": token,
        "TAILMOX_INFLUXDB_ORG": str(data.get("org", "")).strip(),
        "TAILMOX_INFLUXDB_BUCKET": str(data.get("bucket", "")).strip(),
    }

    with open(INFLUX_ENV_FILE, "w", encoding="utf-8") as handle:
        handle.write("# Tailmox monitor InfluxDB export settings\n")
        for key, value in next_config.items():
            handle.write(f"{key}={shell_quote_env(value)}\n")

    os.environ.update(next_config)
    INFLUX_STATE["lastWriteAt"] = None
    INFLUX_STATE["lastError"] = None
    return influx_settings_payload()


def influx_settings_payload():
    config = influx_config()
    return {
        "url": config["url"],
        "org": config["org"],
        "bucket": config["bucket"],
        "tokenConfigured": bool(config["token"]),
        "enabled": influx_enabled(),
        "lastWriteAt": INFLUX_STATE["lastWriteAt"],
        "lastError": INFLUX_STATE["lastError"],
    }


def request_identity(headers):
    return headers.get("Tailscale-User-Login", "")


def influx_enabled():
    config = influx_config()
    return all(config.values())


def escape_tag(value):
    return str(value).replace("\\", "\\\\").replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")


def escape_string(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def field_value(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return f"{value}i"
    if isinstance(value, float):
        return str(value)
    return f'"{escape_string(value)}"'


def line_protocol(measurement, tags, fields, timestamp):
    tag_text = "".join(f",{escape_tag(key)}={escape_tag(value)}" for key, value in tags.items() if value not in (None, ""))
    field_parts = [f"{escape_tag(key)}={encoded}" for key, value in fields.items() if (encoded := field_value(value)) is not None]
    if not field_parts:
        return None
    return f"{escape_tag(measurement)}{tag_text} {','.join(field_parts)} {timestamp}000000000"


def write_influx(lines):
    if not influx_enabled() or not lines:
        return

    config = influx_config()
    query = urllib.parse.urlencode({"org": config["org"], "bucket": config["bucket"], "precision": "ns"})
    request = urllib.request.Request(
        f"{config['url']}/api/v2/write?{query}",
        data=("\n".join(lines) + "\n").encode("utf-8"),
        headers={
            "Authorization": f"Token {config['token']}",
            "Content-Type": "text/plain; charset=utf-8",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status >= 300:
                INFLUX_STATE["lastError"] = f"HTTP {response.status}"
                return
        INFLUX_STATE["lastWriteAt"] = int(time.time())
        INFLUX_STATE["lastError"] = None
    except (urllib.error.URLError, TimeoutError) as error:
        INFLUX_STATE["lastError"] = str(error)


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
    by_nodeid = {}
    for line in output.splitlines():
        match = re.match(r"runtime\.members\.(\d+)\.([a-z_]+) .* = (.*)", line.strip())
        if not match:
            continue
        nodeid, key, value = match.groups()
        member = by_nodeid.setdefault(nodeid, {"nodeid": nodeid})
        value = value.strip()
        if key == "ip":
            ip_match = re.search(r"ip\(([^)]+)\)", value)
            member["ip"] = ip_match.group(1) if ip_match else value
        elif key in ("status", "join_count", "config_version"):
            member[key] = value
    members = list(by_nodeid.values())
    return members


def measure_link_quality(members, local_ips):
    results = []
    for member in members:
        ip = member.get("ip")
        if not ip or ip in local_ips:
            continue

        ping = run_command(["ping", "-c", "8", "-i", "0.2", "-W", "1", ip], timeout=5)
        output = "\n".join(item for item in [ping["stdout"], ping["stderr"]] if item)
        loss = None
        min_ms = avg_ms = max_ms = jitter_ms = None

        loss_match = re.search(r"([0-9.]+)% packet loss", output)
        if loss_match:
            loss = float(loss_match.group(1))

        rtt_match = re.search(r"(?:rtt|round-trip) min/avg/max/(?:mdev|stddev) = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)", output)
        if rtt_match:
            min_ms, avg_ms, max_ms, jitter_ms = [float(value) for value in rtt_match.groups()]

        if loss is None:
            quality = "unknown"
        elif loss > 0:
            quality = "loss"
        elif jitter_ms is not None and jitter_ms > 20:
            quality = "jittery"
        elif avg_ms is not None and avg_ms > 150:
            quality = "slow"
        else:
            quality = "good"

        results.append(
            {
                "nodeid": member.get("nodeid"),
                "ip": ip,
                "status": member.get("status"),
                "quality": quality,
                "packetLossPercent": loss,
                "minMs": min_ms,
                "avgMs": avg_ms,
                "maxMs": max_ms,
                "jitterMs": jitter_ms,
                "raw": output,
            }
        )
    return results


def collect_corosync_members():
    members = run_command(["corosync-cmapctl", "runtime.members"])
    return parse_corosync_members(members["stdout"]) if members["stdout"] else []


def collect_link_quality():
    now = int(time.time())
    if now - LINK_QUALITY_CACHE["generatedAt"] < LINK_QUALITY_TTL_SECONDS:
        return LINK_QUALITY_CACHE

    corosync_members = collect_corosync_members()
    local_ips = set(run_command(["tailscale", "ip", "-4"])["stdout"].splitlines())
    LINK_QUALITY_CACHE["generatedAt"] = now
    LINK_QUALITY_CACHE["links"] = measure_link_quality(corosync_members, local_ips)
    export_link_quality(LINK_QUALITY_CACHE["links"], now)
    return LINK_QUALITY_CACHE


def export_link_quality(links, timestamp):
    lines = []
    hostname = socket.gethostname()
    for link in links:
        lines.append(
            line_protocol(
                "tailmox_corosync_link_quality",
                {"host": hostname, "peer_ip": link.get("ip"), "nodeid": link.get("nodeid")},
                {
                    "packet_loss_percent": link.get("packetLossPercent"),
                    "min_ms": link.get("minMs"),
                    "avg_ms": link.get("avgMs"),
                    "max_ms": link.get("maxMs"),
                    "jitter_ms": link.get("jitterMs"),
                    "quality": link.get("quality"),
                    "joined": link.get("status") == "joined",
                },
                timestamp,
            )
        )
    write_influx([line for line in lines if line])


def export_status(status):
    timestamp = status["generatedAt"]
    cluster = status["cluster"]
    services = status["services"]

    def integer(value):
        try:
            return int(str(value).strip())
        except (TypeError, ValueError):
            return None

    line = line_protocol(
        "tailmox_cluster_status",
        {"host": status["hostname"], "cluster": cluster.get("name")},
        {
            "healthy": status["overall"] == "healthy",
            "corosync_active": services["corosync"]["active"],
            "pve_cluster_active": services["pveCluster"]["active"],
            "quorate": cluster.get("quorate") == "Yes",
            "expected_votes": integer(cluster.get("expectedVotes")),
            "total_votes": integer(cluster.get("totalVotes")),
            "highest_expected": integer(cluster.get("highestExpected")),
            "member_count": len(status["corosync"]["members"]),
            "quorum_node_count": len(status["corosync"]["quorumNodes"]),
        },
        timestamp,
    )
    write_influx([line] if line else [])


def collect_status():
    service = run_command(["systemctl", "is-active", "corosync"])
    enabled = run_command(["systemctl", "is-enabled", "corosync"])
    pve_cluster = run_command(["systemctl", "is-active", "pve-cluster"])
    pvecm = run_command(["pvecm", "status"])
    quorum = run_command(["corosync-quorumtool", "-s"])
    tailscale = run_command(["tailscale", "status", "--json"])
    journal = run_command(["journalctl", "-u", "corosync", "-n", "25", "--no-pager"], timeout=8)

    pvecm_fields = parse_pvecm_status(pvecm["stdout"]) if pvecm["stdout"] else {}
    quorum_nodes = parse_quorum(quorum["stdout"]) if quorum["stdout"] else []
    corosync_members = collect_corosync_members()

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

    status = {
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
                for item in [pvecm, quorum, journal]
                if item["stderr"] and item["returncode"] not in (0, 1)
            ],
        },
        "tailscale": {
            "self": tailscale_data.get("Self", {}),
            "backendState": tailscale_data.get("BackendState"),
        },
        "influxdb": {
            "enabled": influx_enabled(),
            "lastWriteAt": INFLUX_STATE["lastWriteAt"],
            "lastError": INFLUX_STATE["lastError"],
        },
    }
    export_status(status)
    return status


INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tailmox Monitor</title>
  <style>
    :root { color-scheme: dark; --bg: #0b1020; --panel: #111827; --line: #334155; --text: #e5e7eb; --muted: #9ca3af; --good: #22c55e; --warn: #f59e0b; --bad: #ef4444; --accent: #38bdf8; --violet: #a78bfa; --rose: #fb7185; --teal: #2dd4bf; }
    body { margin: 0; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: radial-gradient(circle at top left, rgba(56,189,248,0.18), transparent 34%), linear-gradient(135deg, #0b1020 0%, #111827 48%, #14213d 100%); color: var(--text); min-height: 100vh; }
    main { max-width: 1180px; margin: 0 auto; padding: 28px; }
    header { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; margin-bottom: 24px; }
    h1 { font-size: 30px; margin: 0 0 6px; color: #f8fafc; }
    h2 { font-size: 15px; margin: 0 0 14px; color: var(--muted); font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; }
    .muted { color: var(--muted); }
    .grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 14px; }
    .wide { grid-column: span 2; }
    .full { grid-column: 1 / -1; }
    .panel { position: relative; overflow: hidden; border: 1px solid rgba(148,163,184,0.28); border-radius: 8px; padding: 16px; background: linear-gradient(180deg, rgba(17,24,39,0.94), rgba(15,23,42,0.94)); box-shadow: 0 14px 34px rgba(0,0,0,0.24); }
    .panel::before { content: ""; position: absolute; inset: 0 0 auto; height: 4px; background: var(--accent); }
    .panel:nth-child(1)::before { background: var(--teal); }
    .panel:nth-child(2)::before { background: var(--warn); }
    .panel:nth-child(3)::before { background: var(--violet); }
    .panel:nth-child(4)::before { background: var(--accent); }
    .panel:nth-child(5)::before { background: var(--good); }
    .panel:nth-child(6)::before { background: var(--teal); }
    .panel:nth-child(7)::before { background: var(--rose); }
    .metric { font-size: 28px; font-weight: 800; color: #f8fafc; }
    .pill { display: inline-flex; align-items: center; gap: 7px; border: 1px solid rgba(148,163,184,0.32); border-radius: 999px; padding: 7px 12px; font-size: 13px; font-weight: 700; background: rgba(15,23,42,0.72); }
    .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--bad); box-shadow: 0 0 18px var(--bad); }
    .ok { border-color: rgba(34,197,94,0.45); color: #bbf7d0; background: rgba(20,83,45,0.34); }
    .warn { border-color: rgba(245,158,11,0.5); color: #fde68a; background: rgba(120,53,15,0.34); }
    .ok .dot { background: var(--good); box-shadow: 0 0 18px var(--good); }
    .warn .dot { background: var(--warn); box-shadow: 0 0 18px var(--warn); }
    .tag { display: inline-block; border-radius: 999px; padding: 3px 8px; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    .tag.good { color: #bbf7d0; background: rgba(34,197,94,0.18); border: 1px solid rgba(34,197,94,0.34); }
    .tag.slow, .tag.jittery { color: #fde68a; background: rgba(245,158,11,0.18); border: 1px solid rgba(245,158,11,0.34); }
    .tag.loss, .tag.unknown { color: #fecdd3; background: rgba(244,63,94,0.18); border: 1px solid rgba(244,63,94,0.34); }
    .loading { display: inline-flex; align-items: center; gap: 10px; color: var(--muted); }
    .spinner { width: 16px; height: 16px; border: 2px solid rgba(148,163,184,0.28); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    form { display: grid; gap: 14px; max-width: 720px; }
    label { display: grid; gap: 7px; color: #bae6fd; font-size: 13px; font-weight: 700; }
    input { width: 100%; box-sizing: border-box; border: 1px solid rgba(148,163,184,0.34); border-radius: 8px; padding: 11px 12px; color: var(--text); background: rgba(2,6,23,0.42); font: inherit; }
    input:focus { outline: 2px solid rgba(56,189,248,0.34); border-color: var(--accent); }
    button, .button { display: inline-flex; align-items: center; justify-content: center; border: 1px solid rgba(56,189,248,0.42); border-radius: 8px; padding: 10px 14px; color: #e0f2fe; background: rgba(14,116,144,0.32); font: inherit; font-weight: 800; text-decoration: none; cursor: pointer; }
    .actions { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .message { min-height: 20px; color: var(--muted); }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 9px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: #bae6fd; font-size: 13px; font-weight: 700; }
    td { color: #e2e8f0; }
    tr:hover td { background: rgba(56,189,248,0.08); }
    pre { white-space: pre-wrap; overflow: auto; margin: 0; color: #cbd5e1; font-size: 13px; line-height: 1.45; background: rgba(2,6,23,0.42); border-radius: 6px; padding: 12px; }
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
      <div class="panel"><h2>InfluxDB</h2><div class="metric" id="influxState">...</div><div class="muted" id="influxDetail"></div><div style="margin-top: 10px;"><a href="/editInfluxDB">Edit settings</a></div></div>
      <div class="panel wide"><h2>Corosync Members</h2><table><thead><tr><th>Node</th><th>ID</th><th>Status</th></tr></thead><tbody id="members"></tbody></table></div>
      <div class="panel wide"><h2>Quorum Nodes</h2><table><thead><tr><th>Node</th><th>ID</th><th>Votes</th><th>Local</th></tr></thead><tbody id="quorumNodes"></tbody></table></div>
      <div class="panel full"><h2>Corosync Link Quality</h2><table><thead><tr><th>Peer IP</th><th>Status</th><th>Loss</th><th>Avg</th><th>Max</th><th>Jitter</th><th>Quality</th></tr></thead><tbody id="linkQuality"></tbody></table></div>
      <div class="panel full"><h2>Recent Corosync Logs</h2><pre id="logs">Loading...</pre></div>
      <div class="panel full"><h2>Raw Cluster Status</h2><pre id="raw"></pre></div>
    </section>
  </main>
  <script>
    const text = (id, value) => document.getElementById(id).textContent = value || "unknown";
    const yesNo = value => value ? "active" : "inactive";
    const ms = value => Number.isFinite(value) ? `${value.toFixed(1)} ms` : "unknown";
    const percent = value => Number.isFinite(value) ? `${value.toFixed(1)}%` : "unknown";
    const renderLinkQuality = links => {
      document.getElementById("linkQuality").innerHTML = (links || []).map(link => `<tr><td>${link.ip || ""}</td><td>${link.status || ""}</td><td>${percent(link.packetLossPercent)}</td><td>${ms(link.avgMs)}</td><td>${ms(link.maxMs)}</td><td>${ms(link.jitterMs)}</td><td><span class="tag ${link.quality || "unknown"}">${link.quality || "unknown"}</span></td></tr>`).join("") || "<tr><td colspan='7'>No remote corosync links measured</td></tr>";
    };
    async function refreshStatus() {
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
      text("influxState", data.influxdb.enabled ? "enabled" : "off");
      text("influxDetail", data.influxdb.lastError ? `error: ${data.influxdb.lastError}` : (data.influxdb.lastWriteAt ? `last write: ${new Date(data.influxdb.lastWriteAt * 1000).toLocaleTimeString()}` : "not configured"));
      document.getElementById("members").innerHTML = (data.corosync.members || []).map(member => `<tr><td>${member.ip || member.name || ""}</td><td>${member.nodeid || ""}</td><td>${member.status || ""}</td></tr>`).join("") || "<tr><td colspan='3'>No member data available</td></tr>";
      document.getElementById("quorumNodes").innerHTML = (data.corosync.quorumNodes || []).map(node => `<tr><td>${node.name || ""}</td><td>${node.nodeid || ""}</td><td>${node.votes || ""}</td><td>${node.local ? "yes" : ""}</td></tr>`).join("") || "<tr><td colspan='4'>No quorum node data available</td></tr>";
      text("logs", (data.corosync.recentLogs || []).join("\\n") || "No recent corosync logs available.");
      text("raw", data.corosync.rawStatus || "No pvecm status output available.");
    }
    async function refreshLinkQuality() {
      document.getElementById("linkQuality").innerHTML = "<tr><td colspan='7'><span class='loading'><span class='spinner'></span>Measuring corosync link quality...</span></td></tr>";
      const response = await fetch("/api/link-quality", { cache: "no-store" });
      const data = await response.json();
      renderLinkQuality(data.links);
    }
    async function refresh() {
      await refreshStatus();
      refreshLinkQuality();
    }
    refresh();
    setInterval(refreshStatus, 15000);
    setInterval(refreshLinkQuality, 30000);
  </script>
</body>
</html>
"""


EDIT_INFLUX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tailmox InfluxDB Settings</title>
  <style>
    :root { color-scheme: dark; --bg: #0b1020; --panel: #111827; --line: #334155; --text: #e5e7eb; --muted: #9ca3af; --accent: #38bdf8; --good: #22c55e; --bad: #ef4444; }
    body { margin: 0; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: radial-gradient(circle at top left, rgba(56,189,248,0.18), transparent 34%), linear-gradient(135deg, #0b1020 0%, #111827 48%, #14213d 100%); color: var(--text); min-height: 100vh; }
    main { max-width: 860px; margin: 0 auto; padding: 28px; }
    header { display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; margin-bottom: 24px; }
    h1 { font-size: 30px; margin: 0 0 6px; color: #f8fafc; }
    h2 { font-size: 15px; margin: 0 0 14px; color: var(--muted); font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; }
    .muted { color: var(--muted); }
    .panel { position: relative; overflow: hidden; border: 1px solid rgba(148,163,184,0.28); border-radius: 8px; padding: 18px; background: linear-gradient(180deg, rgba(17,24,39,0.94), rgba(15,23,42,0.94)); box-shadow: 0 14px 34px rgba(0,0,0,0.24); }
    .panel::before { content: ""; position: absolute; inset: 0 0 auto; height: 4px; background: var(--accent); }
    form { display: grid; gap: 14px; }
    label { display: grid; gap: 7px; color: #bae6fd; font-size: 13px; font-weight: 700; }
    input { width: 100%; box-sizing: border-box; border: 1px solid rgba(148,163,184,0.34); border-radius: 8px; padding: 11px 12px; color: var(--text); background: rgba(2,6,23,0.42); font: inherit; }
    input:focus { outline: 2px solid rgba(56,189,248,0.34); border-color: var(--accent); }
    button, .button { display: inline-flex; align-items: center; justify-content: center; border: 1px solid rgba(56,189,248,0.42); border-radius: 8px; padding: 10px 14px; color: #e0f2fe; background: rgba(14,116,144,0.32); font: inherit; font-weight: 800; text-decoration: none; cursor: pointer; }
    .actions { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .message { min-height: 20px; color: var(--muted); }
    .ok { color: #bbf7d0; }
    .error { color: #fecdd3; }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>InfluxDB Settings</h1>
        <div class="muted">Configure Tailmox monitor exports for this node.</div>
      </div>
      <a class="button" href="/">Back to monitor</a>
    </header>
    <section class="panel">
      <h2>Export Destination</h2>
      <form id="influxForm">
        <label>InfluxDB URL<input id="url" name="url" autocomplete="url" placeholder="https://influxdb.example.com"></label>
        <label>Organization<input id="org" name="org" autocomplete="off"></label>
        <label>Bucket<input id="bucket" name="bucket" autocomplete="off"></label>
        <label>Token<input id="token" name="token" type="password" autocomplete="new-password" placeholder="Leave blank to keep the current token"></label>
        <div class="actions">
          <button type="submit">Save settings</button>
          <span class="message" id="message"></span>
        </div>
      </form>
    </section>
  </main>
  <script>
    const csrfToken = "__CSRF_TOKEN__";
    const message = document.getElementById("message");
    async function loadSettings() {
      const response = await fetch("/api/influxdb", { cache: "no-store" });
      const data = await response.json();
      document.getElementById("url").value = data.url || "";
      document.getElementById("org").value = data.org || "";
      document.getElementById("bucket").value = data.bucket || "";
      document.getElementById("token").placeholder = data.tokenConfigured ? "Current token is saved; leave blank to keep it" : "Paste an InfluxDB token";
    }
    document.getElementById("influxForm").addEventListener("submit", async event => {
      event.preventDefault();
      message.className = "message";
      message.textContent = "Saving...";
      const body = {
        url: document.getElementById("url").value,
        org: document.getElementById("org").value,
        bucket: document.getElementById("bucket").value,
        token: document.getElementById("token").value,
      };
      const response = await fetch("/api/influxdb", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
        body: JSON.stringify(body),
      });
      const data = await response.json();
      if (response.ok) {
        document.getElementById("token").value = "";
        document.getElementById("token").placeholder = data.tokenConfigured ? "Current token is saved; leave blank to keep it" : "Paste an InfluxDB token";
        message.className = "message ok";
        message.textContent = data.enabled ? "Saved. Export is enabled." : "Saved. Add all fields to enable export.";
      } else {
        message.className = "message error";
        message.textContent = data.error || "Unable to save settings.";
      }
    });
    loadSettings();
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def send_body(self, status, content_type, body, extra_headers=None):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(encoded)

    def send_json(self, status, payload):
        self.send_body(status, "application/json", json.dumps(payload))

    def require_tailscale_user(self):
        login = request_identity(self.headers)
        if login:
            return login
        self.send_json(403, {"error": "InfluxDB settings require Tailscale Serve user identity."})
        return None

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self.send_body(200, "text/html; charset=utf-8", INDEX_HTML)
        elif path == "/editInfluxDB":
            if not self.require_tailscale_user():
                return
            self.send_body(
                200,
                "text/html; charset=utf-8",
                EDIT_INFLUX_HTML.replace("__CSRF_TOKEN__", CSRF_TOKEN),
                {"Set-Cookie": "tailmox_csrf=1; Path=/; SameSite=Strict; Secure"},
            )
        elif path == "/api/status":
            self.send_json(200, collect_status())
        elif path == "/api/link-quality":
            self.send_json(200, collect_link_quality())
        elif path == "/api/influxdb":
            if not self.require_tailscale_user():
                return
            self.send_json(200, influx_settings_payload())
        else:
            self.send_body(404, "text/plain; charset=utf-8", "not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/influxdb":
            self.send_body(404, "text/plain; charset=utf-8", "not found")
            return
        if not self.require_tailscale_user():
            return
        if self.headers.get("X-CSRF-Token") != CSRF_TOKEN:
            self.send_json(403, {"error": "Invalid CSRF token."})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
            settings = save_influx_config(payload)
            self.send_json(200, settings)
        except (OSError, json.JSONDecodeError) as error:
            self.send_json(500, {"error": str(error)})

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Tailmox monitor listening on http://{HOST}:{PORT}")
    server.serve_forever()
