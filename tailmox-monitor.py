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
LINK_QUALITY_HISTORY_LIMIT = 120
LINK_QUALITY_HISTORY = {}
INFLUX_STATE = {"lastWriteAt": None, "lastError": None}
CSRF_TOKEN = secrets.token_urlsafe(32)
MTU_HISTORY_LIMIT = 120
MTU_HISTORY = []
MEMBER_COUNT_HISTORY_LIMIT = 120
MEMBER_COUNT_HISTORY = []


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


def parse_configured_nodes(output):
    by_index = {}
    for line in output.splitlines():
        match = re.match(r"nodelist\.node\.(\d+)\.([a-z0-9_]+) .* = (.*)", line.strip())
        if not match:
            continue
        index, key, value = match.groups()
        node = by_index.setdefault(index, {})
        node[key] = value.strip()
    return sorted(by_index.values(), key=lambda node: int_or_none(node.get("nodeid")) or 0)


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


def measure_link_quality(members, local_ips, measured_at):
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
                "lastUpdatedAt": measured_at,
                "raw": output,
            }
        )
    return results


def collect_corosync_members():
    members = run_command(["corosync-cmapctl", "runtime.members"])
    return parse_corosync_members(members["stdout"]) if members["stdout"] else []


def collect_configured_nodes():
    nodes = run_command(["corosync-cmapctl", "nodelist"])
    return parse_configured_nodes(nodes["stdout"]) if nodes["stdout"] else []


def corosync_member_health(configured_nodes, corosync_members, quorum_nodes):
    members_by_nodeid = {member.get("nodeid"): member for member in corosync_members}
    quorum_by_nodeid = {node.get("nodeid"): node for node in quorum_nodes}
    configured_by_nodeid = {node.get("nodeid"): node for node in configured_nodes}
    nodeids = sorted(
        {nodeid for nodeid in [*configured_by_nodeid, *members_by_nodeid, *quorum_by_nodeid] if nodeid},
        key=lambda nodeid: int_or_none(nodeid) or 0,
    )
    health = []
    for nodeid in nodeids:
        configured = configured_by_nodeid.get(nodeid, {})
        member = members_by_nodeid.get(nodeid, {})
        quorum = quorum_by_nodeid.get(nodeid, {})
        status = member.get("status") or "offline"
        health.append(
            {
                "nodeid": nodeid,
                "name": configured.get("name") or quorum.get("name") or member.get("name") or "",
                "ip": member.get("ip") or configured.get("ring0_addr") or "",
                "votes": int_or_none(configured.get("quorum_votes")) or int_or_none(quorum.get("votes")),
                "local": bool(quorum.get("local")),
                "status": status,
                "active": status == "joined",
                "configured": nodeid in configured_by_nodeid,
                "join_count": member.get("join_count"),
                "config_version": member.get("config_version"),
            }
        )
    return health


def parse_cmap_value(output, key):
    for line in output.splitlines():
        match = re.match(rf"{re.escape(key)} .* = (.*)", line.strip())
        if match:
            return match.group(1).strip()
    return None


def int_or_none(value):
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def collect_mtu_status():
    now = int(time.time())
    cmap_keys = [
        "runtime.config.totem.knet_mtu",
        "runtime.config.totem.knet_pmtud_interval",
        "runtime.config.totem.interface.0.knet_ping_interval",
        "runtime.config.totem.interface.0.knet_ping_timeout",
        "runtime.config.totem.token",
        "runtime.config.totem.token_retransmit",
        "runtime.config.totem.token_retransmits_before_loss_const",
        "runtime.config.totem.consensus",
        "runtime.config.totem.max_network_delay",
        "runtime.config.totem.max_messages",
        "runtime.config.totem.window_size",
        "runtime.config.totem.knet_compression_threshold",
        "runtime.config.totem.knet_compression_level",
    ]
    cmap = run_command(["corosync-cmapctl", *cmap_keys])
    journal = run_command(["journalctl", "-u", "corosync", "-n", "250", "--no-pager"], timeout=8)
    raw_mtu = parse_cmap_value(cmap["stdout"], "runtime.config.totem.knet_mtu")
    mtu = int_or_none(raw_mtu)
    discovered_mtu = None
    for match in re.finditer(r"Global data MTU changed to:\s*([0-9]+)", journal["stdout"]):
        discovered_mtu = int_or_none(match.group(1))

    sample = {
        "timestamp": now,
        "configuredMtu": mtu,
        "discoveredGlobalMtu": discovered_mtu,
        "displayMtu": discovered_mtu if discovered_mtu is not None else mtu,
        "automatic": mtu == 0,
        "pmtudIntervalSeconds": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.knet_pmtud_interval")),
        "knetPingIntervalMs": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.interface.0.knet_ping_interval")),
        "knetPingTimeoutMs": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.interface.0.knet_ping_timeout")),
        "tokenMs": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.token")),
        "tokenRetransmitMs": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.token_retransmit")),
        "tokenRetransmitsBeforeLoss": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.token_retransmits_before_loss_const")),
        "consensusMs": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.consensus")),
        "maxNetworkDelayMs": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.max_network_delay")),
        "maxMessages": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.max_messages")),
        "windowSize": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.window_size")),
        "knetCompressionThreshold": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.knet_compression_threshold")),
        "knetCompressionLevel": int_or_none(parse_cmap_value(cmap["stdout"], "runtime.config.totem.knet_compression_level")),
    }
    if not MTU_HISTORY or MTU_HISTORY[-1]["timestamp"] != now:
        MTU_HISTORY.append(sample)
        del MTU_HISTORY[:-MTU_HISTORY_LIMIT]
        export_mtu_status(sample)

    return {
        "generatedAt": now,
        "current": sample,
        "history": MTU_HISTORY,
    }


def export_mtu_status(sample):
    line = line_protocol(
        "tailmox_corosync_config",
        {"host": socket.gethostname()},
        {
            "configured_mtu": sample.get("configuredMtu"),
            "discovered_global_mtu": sample.get("discoveredGlobalMtu"),
            "display_mtu": sample.get("displayMtu"),
            "automatic": sample.get("automatic"),
            "pmtud_interval_seconds": sample.get("pmtudIntervalSeconds"),
            "knet_ping_interval_ms": sample.get("knetPingIntervalMs"),
            "knet_ping_timeout_ms": sample.get("knetPingTimeoutMs"),
            "token_ms": sample.get("tokenMs"),
            "token_retransmit_ms": sample.get("tokenRetransmitMs"),
            "token_retransmits_before_loss": sample.get("tokenRetransmitsBeforeLoss"),
            "consensus_ms": sample.get("consensusMs"),
            "max_network_delay_ms": sample.get("maxNetworkDelayMs"),
            "max_messages": sample.get("maxMessages"),
            "window_size": sample.get("windowSize"),
            "knet_compression_threshold": sample.get("knetCompressionThreshold"),
            "knet_compression_level": sample.get("knetCompressionLevel"),
        },
        sample["timestamp"],
    )
    write_influx([line] if line else [])


def collect_link_quality():
    now = int(time.time())
    if now - LINK_QUALITY_CACHE["generatedAt"] < LINK_QUALITY_TTL_SECONDS:
        return LINK_QUALITY_CACHE

    corosync_members = collect_corosync_members()
    local_ips = set(run_command(["tailscale", "ip", "-4"])["stdout"].splitlines())
    tailscale = run_command(["tailscale", "status", "--json"])
    peer_names = {}
    if tailscale["stdout"]:
        try:
            tailscale_data = json.loads(tailscale["stdout"])
            for peer in tailscale_data.get("Peer", {}).values():
                for ip in peer.get("TailscaleIPs", []):
                    peer_names[ip] = peer.get("HostName") or peer.get("DNSName") or ip
        except json.JSONDecodeError:
            peer_names = {}
    LINK_QUALITY_CACHE["generatedAt"] = now
    LINK_QUALITY_CACHE["links"] = measure_link_quality(corosync_members, local_ips, now)
    for link in LINK_QUALITY_CACHE["links"]:
        link["hostname"] = peer_names.get(link.get("ip"), "")
        key = link.get("hostname") or link.get("ip")
        if key:
            samples = LINK_QUALITY_HISTORY.setdefault(key, [])
            samples.append(
                {
                    "timestamp": now,
                    "hostname": link.get("hostname"),
                    "ip": link.get("ip"),
                    "avgMs": link.get("avgMs"),
                    "maxMs": link.get("maxMs"),
                    "jitterMs": link.get("jitterMs"),
                    "packetLossPercent": link.get("packetLossPercent"),
                }
            )
            del samples[:-LINK_QUALITY_HISTORY_LIMIT]
    export_link_quality(LINK_QUALITY_CACHE["links"], now)
    return LINK_QUALITY_CACHE


def collect_link_quality_history():
    if not LINK_QUALITY_HISTORY:
        collect_link_quality()
    return {
        "generatedAt": int(time.time()),
        "series": [
            {
                "name": name,
                "samples": samples,
            }
            for name, samples in sorted(LINK_QUALITY_HISTORY.items())
        ],
    }


def export_link_quality(links, timestamp):
    lines = []
    hostname = socket.gethostname()
    for link in links:
        lines.append(
            line_protocol(
                "tailmox_corosync_link_quality",
                {
                    "host": hostname,
                    "peer_host": link.get("hostname"),
                    "peer_ip": link.get("ip"),
                    "nodeid": link.get("nodeid"),
                },
                {
                    "packet_loss_percent": link.get("packetLossPercent"),
                    "min_ms": link.get("minMs"),
                    "avg_ms": link.get("avgMs"),
                    "max_ms": link.get("maxMs"),
                    "jitter_ms": link.get("jitterMs"),
                    "quality": link.get("quality"),
                    "status": link.get("status"),
                    "joined": link.get("status") == "joined",
                },
                timestamp,
            )
        )
    write_influx([line for line in lines if line])


def export_corosync_members(members, timestamp):
    lines = []
    hostname = socket.gethostname()
    for member in members:
        lines.append(
            line_protocol(
                "tailmox_corosync_member",
                {"host": hostname, "nodeid": member.get("nodeid"), "member_ip": member.get("ip")},
                {
                    "joined": member.get("active"),
                    "configured": member.get("configured"),
                    "status": member.get("status"),
                    "join_count": int_or_none(member.get("join_count")),
                    "config_version": int_or_none(member.get("config_version")),
                    "votes": int_or_none(member.get("votes")),
                    "local": bool(member.get("local")),
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
            "corosync_enabled": services["corosync"]["enabled"] == "enabled",
            "pve_cluster_active": services["pveCluster"]["active"],
            "quorate": cluster.get("quorate") == "Yes",
            "config_version": integer(cluster.get("configVersion")),
            "transport": cluster.get("transport"),
            "secure_auth": cluster.get("secureAuth") == "on",
            "expected_votes": integer(cluster.get("expectedVotes")),
            "total_votes": integer(cluster.get("totalVotes")),
            "highest_expected": integer(cluster.get("highestExpected")),
            "member_count": sum(1 for member in status["corosync"]["members"] if member.get("active")),
            "quorum_node_count": len(status["corosync"]["quorumNodes"]),
            "configured_node_count": len(status["corosync"]["configuredNodes"]),
            "offline_node_count": sum(1 for member in status["corosync"]["members"] if not member.get("active")),
        },
        timestamp,
    )
    write_influx([line] if line else [])
    export_corosync_members(status["corosync"]["members"], timestamp)


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
    configured_nodes = collect_configured_nodes()
    member_health = corosync_member_health(configured_nodes, corosync_members, quorum_nodes)

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
    offline_members = [member for member in member_health if not member.get("active")]
    healthy = corosync_active and pve_cluster_active and quorate == "Yes" and not offline_members
    member_count_sample = {
        "timestamp": int(time.time()),
        "memberCount": len(corosync_members),
        "quorumNodeCount": len(quorum_nodes),
    }
    if not MEMBER_COUNT_HISTORY or MEMBER_COUNT_HISTORY[-1]["timestamp"] != member_count_sample["timestamp"]:
        MEMBER_COUNT_HISTORY.append(member_count_sample)
        del MEMBER_COUNT_HISTORY[:-MEMBER_COUNT_HISTORY_LIMIT]

    status = {
        "generatedAt": member_count_sample["timestamp"],
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
            "members": member_health,
            "activeMembers": corosync_members,
            "configuredNodes": configured_nodes,
            "offlineMembers": offline_members,
            "quorumNodes": quorum_nodes,
            "mtu": collect_mtu_status()["current"],
            "memberCount": member_count_sample,
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


def collect_member_count_history():
    if not MEMBER_COUNT_HISTORY:
        status = collect_status()
        return {
            "generatedAt": status["generatedAt"],
            "current": status["corosync"]["memberCount"],
            "history": MEMBER_COUNT_HISTORY,
        }
    return {
        "generatedAt": int(time.time()),
        "current": MEMBER_COUNT_HISTORY[-1],
        "history": MEMBER_COUNT_HISTORY,
    }


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
    .tag.loss, .tag.unknown, .tag.offline { color: #fecdd3; background: rgba(244,63,94,0.18); border: 1px solid rgba(244,63,94,0.34); }
    .tag.joined { color: #bbf7d0; background: rgba(34,197,94,0.18); border: 1px solid rgba(34,197,94,0.34); }
    .metric-cell { border-radius: 6px; padding: 4px 8px; font-weight: 800; }
    .metric-cell.good { color: #bbf7d0; background: rgba(34,197,94,0.12); }
    .metric-cell.warn { color: #fde68a; background: rgba(245,158,11,0.14); }
    .metric-cell.bad { color: #fecdd3; background: rgba(244,63,94,0.14); }
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
    .chart { width: 100%; height: 220px; display: block; background: rgba(2,6,23,0.42); border: 1px solid rgba(148,163,184,0.18); border-radius: 8px; }
    .chart text { fill: var(--muted); font-size: 12px; }
    .chart .grid-line { stroke: rgba(148,163,184,0.18); stroke-width: 1; }
    .chart .series { fill: none; stroke: var(--accent); stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; }
    .chart .point { fill: var(--accent); }
    .legend { display: flex; flex-wrap: wrap; gap: 8px 14px; margin-top: 10px; color: var(--muted); font-size: 13px; }
    .legend-item { display: inline-flex; align-items: center; gap: 7px; }
    .swatch { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
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
      <div class="panel wide"><h2>Corosync Members</h2><table><thead><tr><th>Node</th><th>Peer IP</th><th>ID</th><th>Votes</th><th>Status</th></tr></thead><tbody id="members"></tbody></table></div>
      <div class="panel wide"><h2>Quorum Nodes</h2><table><thead><tr><th>Node</th><th>ID</th><th>Votes</th><th>Local</th></tr></thead><tbody id="quorumNodes"></tbody></table></div>
      <div class="panel full"><h2>Global MTU Over Time</h2><div class="muted" id="mtuDetail">Loading MTU history...</div><svg class="chart" id="mtuChart" viewBox="0 0 900 220" role="img" aria-label="Global MTU over time"></svg></div>
      <div class="panel full"><h2>Cluster Members Over Time</h2><div class="muted" id="memberCountDetail">Loading member history...</div><svg class="chart" id="memberCountChart" viewBox="0 0 900 220" role="img" aria-label="Cluster members over time"></svg></div>
      <div class="panel full"><h2>Link Quality Over Time</h2><div class="muted" id="linkQualityGraphDetail">Loading link-quality history...</div><svg class="chart" id="linkQualityChart" viewBox="0 0 900 220" role="img" aria-label="Link quality over time"></svg><div class="legend" id="linkQualityLegend"></div></div>
      <div class="panel full"><h2>Corosync Link Quality</h2><table><thead><tr><th>Hostname</th><th>Peer IP</th><th>Status</th><th>Loss</th><th>Avg</th><th>Max</th><th>Jitter</th><th>Quality</th><th>Last updated</th></tr></thead><tbody id="linkQuality"></tbody></table></div>
      <div class="panel full"><h2>Recent Corosync Logs</h2><pre id="logs">Loading...</pre></div>
      <div class="panel full"><h2>Raw Cluster Status</h2><pre id="raw"></pre></div>
    </section>
  </main>
  <script>
    const text = (id, value) => document.getElementById(id).textContent = value || "unknown";
    const yesNo = value => value ? "active" : "inactive";
    const ms = value => Number.isFinite(value) ? `${value.toFixed(1)} ms` : "unknown";
    const percent = value => Number.isFinite(value) ? `${value.toFixed(1)}%` : "unknown";
    const localTime = value => Number.isFinite(value) ? new Date(value * 1000).toLocaleTimeString() : "unknown";
    const qualityClass = (value, warn, bad) => !Number.isFinite(value) ? "bad" : value >= bad ? "bad" : value >= warn ? "warn" : "good";
    const metricCell = (value, text, warn, bad) => `<span class="metric-cell ${qualityClass(value, warn, bad)}">${text}</span>`;
    const number = value => Number.isFinite(value) ? value.toLocaleString() : "auto";
    const timeLabel = value => new Date(value * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" });
    const seriesColors = ["#38bdf8", "#2dd4bf", "#a78bfa", "#fb7185", "#f59e0b", "#22c55e", "#e879f9", "#60a5fa"];
    const svg = (name, attrs = {}, content = "") => `<${name} ${Object.entries(attrs).map(([key, value]) => `${key}="${value}"`).join(" ")}>${content}</${name}>`;
    const renderLineChart = (chart, history, valueKey, emptyText, formatLabel = number) => {
      if (!history.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, emptyText);
        return;
      }
      const width = 900, height = 220, left = 58, right = 20, top = 20, bottom = 38;
      const minTime = history[0].timestamp;
      const maxTime = history[history.length - 1].timestamp || minTime + 1;
      const values = history.map(sample => sample[valueKey]);
      const minValue = Math.min(...values);
      const maxValue = Math.max(...values);
      const flat = minValue === maxValue;
      const padding = flat ? Math.max(1, Math.round(maxValue * 0.05)) : 0;
      const chartMin = Math.max(0, minValue - padding);
      const chartMax = maxValue + padding;
      const span = Math.max(1, chartMax - chartMin);
      const x = sample => left + ((sample.timestamp - minTime) / Math.max(1, maxTime - minTime)) * (width - left - right);
      const y = sample => top + (1 - ((sample[valueKey] - chartMin) / span)) * (height - top - bottom);
      const points = history.map(sample => `${x(sample).toFixed(1)},${y(sample).toFixed(1)}`).join(" ");
      const midValue = chartMin + span / 2;
      chart.innerHTML = [
        svg("line", { class: "grid-line", x1: left, y1: top, x2: left, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: height - bottom, x2: width - right, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: top, x2: width - right, y2: top }),
        svg("text", { x: 10, y: top + 4 }, formatLabel(chartMax)),
        svg("text", { x: 10, y: y({ [valueKey]: midValue }) + 4 }, formatLabel(Math.round(midValue))),
        svg("text", { x: 10, y: height - bottom + 4 }, formatLabel(chartMin)),
        svg("text", { x: left, y: height - 12 }, timeLabel(minTime)),
        svg("text", { x: width / 2 - 34, y: height - 12 }, timeLabel(minTime + (maxTime - minTime) / 2)),
        svg("text", { x: width - right - 72, y: height - 12 }, timeLabel(maxTime)),
        `<polyline class="series" points="${points}"></polyline>`,
        history.map(sample => svg("circle", { class: "point", cx: x(sample).toFixed(1), cy: y(sample).toFixed(1), r: 3 })).join(""),
      ].join("");
    };
    const renderLinkQuality = links => {
      document.getElementById("linkQuality").innerHTML = (links || []).map(link => `<tr><td>${link.hostname || "unknown"}</td><td>${link.ip || ""}</td><td>${link.status || ""}</td><td>${metricCell(link.packetLossPercent, percent(link.packetLossPercent), 0.1, 1)}</td><td>${metricCell(link.avgMs, ms(link.avgMs), 50, 150)}</td><td>${metricCell(link.maxMs, ms(link.maxMs), 100, 250)}</td><td>${metricCell(link.jitterMs, ms(link.jitterMs), 10, 20)}</td><td><span class="tag ${link.quality || "unknown"}">${link.quality || "unknown"}</span></td><td>${localTime(link.lastUpdatedAt)}</td></tr>`).join("") || "<tr><td colspan='9'>No remote corosync links measured</td></tr>";
    };
    const renderMtu = data => {
      const current = data.current || {};
      const history = (data.history || []).filter(sample => Number.isFinite(sample.displayMtu));
      const discovered = Number.isFinite(current.discoveredGlobalMtu);
      const configured = current.automatic ? "auto" : `${number(current.configuredMtu)} bytes`;
      const plotted = discovered ? `${number(current.discoveredGlobalMtu)} bytes discovered` : configured;
      const detail = `Global data MTU: ${plotted}; configured knet MTU: ${configured}; PMTUD interval: ${current.pmtudIntervalSeconds || "unknown"}s`;
      text("mtuDetail", `${detail}. Samples kept: ${(data.history || []).length}.`);

      const chart = document.getElementById("mtuChart");
      if (!history.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, "No global MTU samples collected yet.");
        return;
      }

      renderLineChart(chart, history, "displayMtu", "No global MTU samples collected yet.", value => value === 0 ? "auto" : number(value));
    };
    const renderMemberCount = data => {
      const current = data.current || {};
      const history = (data.history || []).filter(sample => Number.isFinite(sample.memberCount));
      text("memberCountDetail", `Current members: ${number(current.memberCount)}; quorum nodes: ${number(current.quorumNodeCount)}. Samples kept: ${(data.history || []).length}.`);
      renderLineChart(document.getElementById("memberCountChart"), history, "memberCount", "No member-count samples collected yet.");
    };
    const renderLinkQualityHistory = data => {
      const chart = document.getElementById("linkQualityChart");
      const legend = document.getElementById("linkQualityLegend");
      const series = (data.series || []).map((item, index) => ({
        ...item,
        color: seriesColors[index % seriesColors.length],
        samples: (item.samples || []).filter(sample => Number.isFinite(sample.avgMs)),
      })).filter(item => item.samples.length);
      const totalSamples = series.reduce((sum, item) => sum + item.samples.length, 0);
      text("linkQualityGraphDetail", `Average latency by host. Series: ${series.length}; samples: ${totalSamples}.`);
      legend.innerHTML = series.map(item => `<span class="legend-item"><span class="swatch" style="background:${item.color}"></span>${item.name}</span>`).join("");
      if (!series.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, "No link-quality history collected yet.");
        return;
      }
      const allSamples = series.flatMap(item => item.samples);
      const width = 900, height = 220, left = 58, right = 20, top = 20, bottom = 38;
      const minTime = Math.min(...allSamples.map(sample => sample.timestamp));
      const maxTime = Math.max(...allSamples.map(sample => sample.timestamp));
      const values = allSamples.map(sample => sample.avgMs);
      const minValue = Math.min(...values);
      const maxValue = Math.max(...values);
      const flat = minValue === maxValue;
      const padding = flat ? Math.max(1, maxValue * 0.25) : Math.max(0.5, (maxValue - minValue) * 0.12);
      const chartMin = Math.max(0, minValue - padding);
      const chartMax = maxValue + padding;
      const span = Math.max(1, chartMax - chartMin);
      const x = sample => left + ((sample.timestamp - minTime) / Math.max(1, maxTime - minTime)) * (width - left - right);
      const y = sample => top + (1 - ((sample.avgMs - chartMin) / span)) * (height - top - bottom);
      const midValue = chartMin + span / 2;
      const paths = series.map(item => {
        const points = item.samples.map(sample => `${x(sample).toFixed(1)},${y(sample).toFixed(1)}`).join(" ");
        const dots = item.samples.map(sample => svg("circle", { cx: x(sample).toFixed(1), cy: y(sample).toFixed(1), r: 3, fill: item.color })).join("");
        return `<polyline fill="none" stroke="${item.color}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" points="${points}"></polyline>${dots}`;
      }).join("");
      chart.innerHTML = [
        svg("line", { class: "grid-line", x1: left, y1: top, x2: left, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: height - bottom, x2: width - right, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: top, x2: width - right, y2: top }),
        svg("text", { x: 10, y: top + 4 }, ms(chartMax)),
        svg("text", { x: 10, y: top + (height - top - bottom) / 2 + 4 }, ms(midValue)),
        svg("text", { x: 10, y: height - bottom + 4 }, ms(chartMin)),
        svg("text", { x: left, y: height - 12 }, timeLabel(minTime)),
        svg("text", { x: width / 2 - 34, y: height - 12 }, timeLabel(minTime + (maxTime - minTime) / 2)),
        svg("text", { x: width - right - 72, y: height - 12 }, timeLabel(maxTime)),
        paths,
      ].join("");
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
      document.getElementById("members").innerHTML = (data.corosync.members || []).map(member => `<tr><td>${member.name || ""}${member.local ? " (local)" : ""}</td><td>${member.ip || ""}</td><td>${member.nodeid || ""}</td><td>${number(member.votes)}</td><td><span class="tag ${member.active ? "joined" : "offline"}">${member.active ? "active" : "offline"}</span></td></tr>`).join("") || "<tr><td colspan='5'>No member data available</td></tr>";
      document.getElementById("quorumNodes").innerHTML = (data.corosync.quorumNodes || []).map(node => `<tr><td>${node.name || ""}</td><td>${node.nodeid || ""}</td><td>${node.votes || ""}</td><td>${node.local ? "yes" : ""}</td></tr>`).join("") || "<tr><td colspan='4'>No quorum node data available</td></tr>";
      text("logs", (data.corosync.recentLogs || []).join("\\n") || "No recent corosync logs available.");
      text("raw", data.corosync.rawStatus || "No pvecm status output available.");
    }
    async function refreshLinkQuality() {
      document.getElementById("linkQuality").innerHTML = "<tr><td colspan='9'><span class='loading'><span class='spinner'></span>Measuring corosync link quality...</span></td></tr>";
      const response = await fetch("/api/link-quality", { cache: "no-store" });
      const data = await response.json();
      renderLinkQuality(data.links);
      await refreshLinkQualityHistory();
    }
    async function refreshLinkQualityHistory() {
      const response = await fetch("/api/link-quality-history", { cache: "no-store" });
      const data = await response.json();
      renderLinkQualityHistory(data);
    }
    async function refreshMtuHistory() {
      const response = await fetch("/api/mtu-history", { cache: "no-store" });
      const data = await response.json();
      renderMtu(data);
    }
    async function refreshMemberCountHistory() {
      const response = await fetch("/api/member-count-history", { cache: "no-store" });
      const data = await response.json();
      renderMemberCount(data);
    }
    async function refresh() {
      await refreshStatus();
      await Promise.allSettled([
        refreshMtuHistory(),
        refreshMemberCountHistory(),
        refreshLinkQuality(),
      ]);
    }
    refresh();
    setInterval(refreshStatus, 15000);
    setInterval(refreshMtuHistory, 15000);
    setInterval(refreshMemberCountHistory, 15000);
    setInterval(refreshLinkQuality, 30000);
    setInterval(refreshLinkQualityHistory, 30000);
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
        elif path == "/api/link-quality-history":
            self.send_json(200, collect_link_quality_history())
        elif path == "/api/mtu-history":
            self.send_json(200, collect_mtu_status())
        elif path == "/api/member-count-history":
            self.send_json(200, collect_member_count_history())
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
