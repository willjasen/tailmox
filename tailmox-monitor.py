#!/usr/bin/env python3
"""
Tailmox monitoring interface.

Runs a small localhost-only HTTP server that reports Proxmox, Tailscale, and
corosync health for the current node.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import csv
import concurrent.futures
import datetime as dt
import io
import ipaddress
import json
import math
import os
import pathlib
import socket
import subprocess
import threading
import time
import re
import urllib.error
import urllib.parse
import urllib.request
import secrets
import tempfile
from urllib.parse import urlparse

# Keep the sibling configuration module importable when this file is loaded
# through runpy (as the local tests do), where Python does not automatically
# add the script's directory to sys.path.
import sys

MONITOR_DIR = pathlib.Path(__file__).resolve().parent
if str(MONITOR_DIR) not in sys.path:
    sys.path.insert(0, str(MONITOR_DIR))

import tailmox_config
from tailmox_migration_control import MigrationControl, discover_subnets

MIGRATION_CONTROL = MigrationControl()


HOST = os.environ.get("TAILMOX_MONITOR_HOST", "127.0.0.1")
PORT = int(os.environ.get("TAILMOX_MONITOR_PORT", "8088"))
PUBLIC_SNAPSHOT_FILE = os.environ.get("TAILMOX_PUBLIC_SNAPSHOT_FILE", "")
PUBLIC_SNAPSHOT_INTERVAL_SECONDS = max(
    10, int(os.environ.get("TAILMOX_PUBLIC_SNAPSHOT_INTERVAL_SECONDS", "30"))
)
PUBLIC_SNAPSHOT_HISTORY_LIMIT = max(
    30, int(os.environ.get("TAILMOX_PUBLIC_SNAPSHOT_HISTORY_LIMIT", "120"))
)
PUBLIC_SNAPSHOT_HISTORY = []
PUBLIC_MAX_NUMBER = 1_000_000_000_000
PUBLIC_BOOLEAN_SAMPLE_FIELDS = {"automatic", "quorate"}
INFLUX_ENV_FILE = os.environ.get("TAILMOX_INFLUXDB_ENV_FILE", "/etc/tailmox-monitor.env")
LEGACY_CONFIG_FILE = pathlib.Path(
    os.environ.get(
        "TAILMOX_LEGACY_CONFIG_FILE",
        os.environ.get("TAILMOX_CONF_FILE", str(tailmox_config.CLUSTER_DIR / "tailmox.conf")),
    )
)
STATE_FILE = pathlib.Path(os.environ.get("TAILMOX_CLUSTER_STATE_FILE", "/etc/pve/tailmox/state.json"))
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
WEBSERVER_PORT = 8088
WEBSERVER_CHECK_TIMEOUT_SECONDS = float(
    os.environ.get("TAILMOX_WEBSERVER_CHECK_TIMEOUT_SECONDS", "1")
)
INFLUX_HEALTH_TIMEOUT_SECONDS = float(
    os.environ.get("TAILMOX_INFLUX_HEALTH_TIMEOUT_SECONDS", "3")
)
CMAP_STATS_INTERVAL_SECONDS = int(os.environ.get("TAILMOX_CMAP_STATS_INTERVAL_SECONDS", "5"))
CMAP_STATS_THREAD_STARTED = False
MAX_HTTP_THREADS = max(1, int(os.environ.get("TAILMOX_MONITOR_MAX_HTTP_THREADS", "32")))
TAILMOX_COMMAND = os.environ.get(
    "TAILMOX_COMMAND", str(pathlib.Path(__file__).with_name("tailmox"))
)
TAILMOX_DEPLOY_DIR = os.environ.get("TAILMOX_DEPLOY_DIR", "/opt/tailmox")
TAILMOX_GIT_COMMAND = os.environ.get("TAILMOX_GIT_COMMAND", "git")
TAILMOX_SYSTEMCTL_COMMAND = os.environ.get("TAILMOX_SYSTEMCTL_COMMAND", "systemctl")
ACTION_OUTPUT_LIMIT = 100_000
ACTION_LOCK = threading.Lock()
ACTION_STATE = {
    "action": None,
    "status": "idle",
    "startedAt": None,
    "finishedAt": None,
    "exitCode": None,
    "output": "No Tailmox workflow has run from this page yet.",
}
TAILMOX_UPDATE_STATE = {"checkedAt": 0, "available": False, "error": None}
TAILMOX_UPDATE_LOCK = threading.Lock()
ACTION_COMMANDS = {
    "test": ["test"],
    "backup-create": ["backups", "create"],
    "stage": ["stage"],
    "analytics-install": ["analytics", "install"],
    "analytics-restart": ["analytics", "restart"],
    "analytics-uninstall": ["analytics", "uninstall"],
    "redeploy": [],
}


def run_redeploy():
    commands = (([TAILMOX_GIT_COMMAND, "pull", "--ff-only"], TAILMOX_DEPLOY_DIR),
                ([TAILMOX_SYSTEMCTL_COMMAND, "restart", "tailmox-monitor.service"], None))
    output = []
    for command, directory in commands:
        completed = subprocess.run(command, check=False, capture_output=True, text=True,
                                   timeout=120, cwd=directory)
        command_output = "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part.strip())
        output.append(f"$ {' '.join(command)}\n{command_output}".rstrip())
        if completed.returncode != 0:
            return completed.returncode, "\n\n".join(output)
    return 0, "\n\n".join(output)


def action_snapshot():
    with ACTION_LOCK:
        return dict(ACTION_STATE)


def tailmox_update_status():
    now = time.time()
    with TAILMOX_UPDATE_LOCK:
        if now - TAILMOX_UPDATE_STATE["checkedAt"] < 60:
            return dict(TAILMOX_UPDATE_STATE)
    try:
        subprocess.run([TAILMOX_GIT_COMMAND, "fetch", "--quiet"], cwd=TAILMOX_DEPLOY_DIR,
                       check=True, capture_output=True, text=True, timeout=30)
        local = subprocess.run([TAILMOX_GIT_COMMAND, "rev-parse", "HEAD"], cwd=TAILMOX_DEPLOY_DIR,
                                check=True, capture_output=True, text=True, timeout=5).stdout.strip()
        upstream = subprocess.run([TAILMOX_GIT_COMMAND, "rev-parse", "@{u}"], cwd=TAILMOX_DEPLOY_DIR,
                                  check=True, capture_output=True, text=True, timeout=5).stdout.strip()
        result = {"checkedAt": int(now), "available": local != upstream, "error": None}
    except (OSError, subprocess.SubprocessError) as error:
        result = {"checkedAt": int(now), "available": False, "error": str(error)}
    with TAILMOX_UPDATE_LOCK:
        TAILMOX_UPDATE_STATE.update(result)
        return dict(TAILMOX_UPDATE_STATE)


def _run_action(action, auth_key):
    environment = os.environ.copy()
    if action == "stage" and auth_key:
        environment["TAILMOX_AUTH_KEY"] = auth_key
    try:
        if action == "redeploy":
            exit_code, output = run_redeploy()
        else:
            with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as output_file:
                completed = subprocess.run(
                    [TAILMOX_COMMAND, *ACTION_COMMANDS[action]], check=False,
                    stdout=output_file, stderr=subprocess.STDOUT,
                    timeout=3600, env=environment,
                )
                output_file.seek(0)
                output = output_file.read().strip()
            exit_code = completed.returncode
        status = "succeeded" if exit_code == 0 else "failed"
    except (OSError, subprocess.TimeoutExpired) as error:
        output = str(error)
        exit_code = 124 if isinstance(error, subprocess.TimeoutExpired) else 127
        status = "failed"
    with ACTION_LOCK:
        ACTION_STATE.update(
            status=status,
            finishedAt=int(time.time()),
            exitCode=exit_code,
            output=(output or "Workflow completed without output.")[-ACTION_OUTPUT_LIMIT:],
        )


def start_action(action, payload):
    if action not in ACTION_COMMANDS:
        raise ValueError("Unknown Tailmox workflow.")
    auth_key = str(payload.get("authKey", "")).strip() if action == "stage" else ""
    with ACTION_LOCK:
        if ACTION_STATE["status"] == "running" or MIGRATION_CONTROL.busy():
            raise RuntimeError("Another Tailmox workflow is already running.")
        ACTION_STATE.update(
            action=action,
            status="running",
            startedAt=int(time.time()),
            finishedAt=None,
            exitCode=None,
            output="Workflow started. Waiting for output...",
        )
    thread = threading.Thread(target=_run_action, args=(action, auth_key), daemon=True)
    thread.start()
    return action_snapshot()


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
    if not tailmox_config.CONFIG_FILE.is_file():
        legacy = read_legacy_config()
        return influx_values(legacy)
    try:
        config = tailmox_config.current_config()["influxdb"]
        normalized = {
            "url": str(config.get("url", "")).rstrip("/"),
            "token": str(config.get("token", "")),
            "org": str(config.get("org", "")),
            "bucket": str(config.get("bucket", "")),
        }
        if all(normalized.values()):
            return normalized
    except (OSError, tailmox_config.ConfigError) as error:
        INFLUX_STATE["lastError"] = str(error)

    return influx_values(read_legacy_config())


def read_env_config_file(path):
    config = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or "=" not in stripped:
                    continue
                key, value = stripped.split("=", 1)
                config[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return config


def read_legacy_config():
    clustered = read_env_config_file(LEGACY_CONFIG_FILE)
    return clustered or read_env_config_file(INFLUX_ENV_FILE)


def influx_values(values):
    return {
        "url": str(values.get("TAILMOX_INFLUXDB_URL", "")).rstrip("/"),
        "token": str(values.get("TAILMOX_INFLUXDB_TOKEN", "")),
        "org": str(values.get("TAILMOX_INFLUXDB_ORG", "")),
        "bucket": str(values.get("TAILMOX_INFLUXDB_BUCKET", "")),
    }


def remove_legacy_config():
    for path in (LEGACY_CONFIG_FILE, INFLUX_ENV_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def save_influx_config(data):
    current_document = tailmox_config.current_config()
    current = current_document["influxdb"]
    token = str(data.get("token", "")).strip()
    if not token:
        token = str(current.get("token", ""))

    next_config = dict(current_document)
    next_config["influxdb"] = {
        "url": str(data.get("url", "")).strip().rstrip("/"),
        "token": token,
        "org": str(data.get("org", "")).strip(),
        "bucket": str(data.get("bucket", "")).strip(),
    }
    proposal = tailmox_config.propose_config(next_config, "Update InfluxDB export settings")
    INFLUX_STATE["lastWriteAt"] = None
    INFLUX_STATE["lastError"] = None
    payload = influx_settings_payload()
    payload["proposal"] = proposal
    return payload


def initialize_encrypted_configuration(identity_result):
    tailmox_config.enroll_local_host()
    legacy = read_legacy_config()
    if not legacy:
        return identity_result
    if tailmox_config.CONFIG_FILE.is_file():
        encrypted = tailmox_config.current_config().get("influxdb", {})
        if any(str(encrypted.get(key, "")).strip() for key in ("url", "token", "org", "bucket")):
            remove_legacy_config()
            return identity_result
    pending = [
        proposal
        for proposal in tailmox_config.list_proposals()
        if not proposal.get("activated") and not proposal.get("error")
    ]
    if pending:
        identity_result["migrationProposal"] = pending[0]
        return identity_result
    config = tailmox_config.current_config()
    config["influxdb"] = influx_values(legacy)
    identity_result["migrationProposal"] = tailmox_config.propose_config(
        config, "Migrate plaintext Tailmox configuration to encrypted storage"
    )
    if identity_result["migrationProposal"].get("activated"):
        remove_legacy_config()
    return identity_result


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


def encrypted_config_readable():
    if not tailmox_config.CONFIG_FILE.is_file():
        return False
    try:
        tailmox_config.current_config()
        return True
    except (OSError, tailmox_config.ConfigError):
        return False


def request_identity(headers):
    return headers.get("Tailscale-User-Login", "")


def influx_enabled():
    config = influx_config()
    return all(config.values())


def collect_influx_health():
    config = influx_config()
    configured = all(config.values())
    health = {
        "enabled": configured,
        "online": None,
        "detail": "not configured",
        "lastWriteAt": INFLUX_STATE["lastWriteAt"],
        "lastError": INFLUX_STATE["lastError"],
    }
    if not configured:
        return health

    request = urllib.request.Request(
        f"{config['url']}/health",
        headers={"Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=INFLUX_HEALTH_TIMEOUT_SECONDS) as response:
            health["online"] = response.status < 300
            health["detail"] = f"HTTP {response.status}"
    except urllib.error.HTTPError as error:
        health["online"] = False
        health["detail"] = f"HTTP {error.code}"
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        health["online"] = False
        health["detail"] = str(error)
    return health


def collect_tailmox_state(configured_nodes):
    state = {
        "active": False,
        "status": "missing",
        "detail": "state file missing",
        "stateFile": str(STATE_FILE),
        "clusterName": None,
        "memberCount": 0,
        "activeMemberCount": 0,
        "configuredNodeCount": len(configured_nodes),
        "updatedAt": None,
        "localStatus": None,
        "tailscaleConfiguredNodeCount": 0,
    }
    if not STATE_FILE.is_file():
        return state

    try:
        document = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        state["status"] = "error"
        state["detail"] = str(error)
        return state

    members = document.get("members") if isinstance(document, dict) else None
    if not isinstance(members, list):
        state["status"] = "error"
        state["detail"] = "state file has no member list"
        return state

    active_members = [member for member in members if member.get("status") == "active"]
    local_member = next((member for member in members if member.get("name") == socket.gethostname()), None)
    configured_by_name = {node.get("name"): node for node in configured_nodes if node.get("name")}
    active_by_name = {member.get("name"): member for member in active_members if member.get("name")}
    tailscale_configured = 0
    for name, node in configured_by_name.items():
        ring0_addr = node.get("ring0_addr")
        tailscale_addr = active_by_name.get(name, {}).get("tailscaleIPv4")
        if ring0_addr and ring0_addr == tailscale_addr:
            tailscale_configured += 1

    local_active = bool(local_member and local_member.get("status") == "active")
    all_configured_tailmox = bool(configured_nodes) and tailscale_configured == len(configured_nodes)
    extra_active = max(0, len(active_members) - len(configured_nodes))
    missing_active = max(0, len(configured_nodes) - tailscale_configured)

    state.update(
        {
            "active": local_active and all_configured_tailmox,
            "status": "active" if local_active and all_configured_tailmox and extra_active == 0 else "attention",
            "clusterName": (document.get("cluster") or {}).get("name"),
            "memberCount": len(members),
            "activeMemberCount": len(active_members),
            "configuredNodeCount": len(configured_nodes),
            "updatedAt": document.get("updatedAt"),
            "localStatus": local_member.get("status") if local_member else "missing",
            "tailscaleConfiguredNodeCount": tailscale_configured,
        }
    )
    if not local_active:
        state["detail"] = f"local host is {state['localStatus']}"
    elif missing_active:
        state["detail"] = f"{missing_active} configured node(s) are not using Tailmox addresses"
    elif extra_active:
        state["detail"] = f"{extra_active} active state member(s) are not in corosync config"
    else:
        state["detail"] = "all configured corosync nodes match Tailmox state"
    return state


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


def parse_cmap_stat_line(line):
    match = re.match(r"(?P<path>[^ ]+) \((?P<type>[^)]+)\) = (?P<value>.*)", line.strip())
    if not match:
        return None
    value_type = match.group("type")
    if value_type == "str":
        return None
    value_text = match.group("value").strip()
    try:
        value = float(value_text) if "." in value_text else int(value_text)
    except ValueError:
        return None
    return {
        "path": match.group("path"),
        "type": value_type,
        "value": value,
    }


def cmap_stat_tags(path):
    parts = path.split(".")
    tags = {"host": socket.gethostname(), "path": path}
    if len(parts) >= 3:
        tags["family"] = parts[1]
        tags["scope"] = parts[2]
    if len(parts) >= 5 and parts[1] == "knet" and re.match(r"node[0-9]+", parts[2]) and re.match(r"link[0-9]+", parts[3]):
        tags.update(
            {
                "nodeid": parts[2].removeprefix("node"),
                "link": parts[3].removeprefix("link"),
                "metric": ".".join(parts[4:]),
            }
        )
    elif len(parts) >= 4 and parts[1] == "knet":
        tags["metric"] = ".".join(parts[3:])
    elif len(parts) >= 4 and parts[1] == "ipcs" and parts[2] != "global":
        tags.update(
            {
                "service": parts[2],
                "process": parts[3],
                "metric": ".".join(parts[5:] if len(parts) > 5 else parts[4:]),
            }
        )
    elif len(parts) >= 4:
        tags["metric"] = ".".join(parts[3:])
    return tags


def collect_cmap_stats():
    timestamp = int(time.time())
    result = run_command(["corosync-cmapctl", "-m", "stats"], timeout=8)
    if not result["ok"]:
        if result["stderr"]:
            INFLUX_STATE["lastError"] = result["stderr"]
        return 0
    lines = []
    for line in result["stdout"].splitlines():
        stat = parse_cmap_stat_line(line)
        if not stat:
            continue
        tags = cmap_stat_tags(stat["path"])
        if not (tags.get("family") == "knet" and tags.get("nodeid") and tags.get("link") and tags.get("metric")):
            continue
        encoded = line_protocol(
            "tailmox_corosync_cmap_stat",
            tags,
            {"value": stat["value"]},
            timestamp,
        )
        if encoded:
            lines.append(encoded)
    write_influx(lines)
    return len(lines)


def cmap_stats_loop():
    while True:
        try:
            collect_cmap_stats()
        except Exception as error:
            INFLUX_STATE["lastError"] = f"cmap stats export failed: {error}"
        time.sleep(CMAP_STATS_INTERVAL_SECONDS)


def start_cmap_stats_exporter():
    global CMAP_STATS_THREAD_STARTED
    if CMAP_STATS_THREAD_STARTED:
        return
    CMAP_STATS_THREAD_STARTED = True
    thread = threading.Thread(target=cmap_stats_loop, name="tailmox-cmap-stats", daemon=True)
    thread.start()


def influx_query(flux, timeout=8):
    if not influx_enabled():
        return []

    config = influx_config()
    request = urllib.request.Request(
        f"{config['url']}/api/v2/query?{urllib.parse.urlencode({'org': config['org']})}",
        data=json.dumps({"query": flux}).encode("utf-8"),
        headers={
            "Authorization": f"Token {config['token']}",
            "Content-Type": "application/json",
            "Accept": "text/csv",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError) as error:
        INFLUX_STATE["lastError"] = str(error)
        return []

    rows = []
    header = None
    for row in csv.reader(io.StringIO(body)):
        if not row:
            header = None
            continue
        if row[0].startswith("#"):
            continue
        if "_time" in row or "_field" in row or "_measurement" in row:
            header = row
            continue
        if not header:
            continue
        if len(row) < len(header):
            row.extend([""] * (len(header) - len(row)))
        rows.append(dict(zip(header, row)))
    return rows


def influx_time(value):
    if not value:
        return None
    try:
        return int(dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def influx_float(row, key):
    value = row.get(key)
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def influx_int(row, key):
    value = influx_float(row, key)
    return int(value) if value is not None else None


def influx_bool(row, key):
    value = row.get(key)
    if value in (None, ""):
        return None
    return str(value).lower() == "true"


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


def collect_webserver_health(configured_nodes):
    def check(node):
        host = node.get("ring0_addr")
        result = {
            "nodeid": node.get("nodeid"),
            "name": node.get("name") or host or "unknown host",
            "host": host or "",
            "port": WEBSERVER_PORT,
            "running": False,
        }
        if not host:
            result["detail"] = "Tailmox address is missing"
            return result
        try:
            connection = socket.create_connection(
                (host, WEBSERVER_PORT), timeout=WEBSERVER_CHECK_TIMEOUT_SECONDS
            )
            connection.close()
            result["running"] = True
            result["detail"] = "accepting connections"
        except OSError as error:
            result["detail"] = str(error) or "connection failed"
        return result

    if not configured_nodes:
        return {"port": WEBSERVER_PORT, "hosts": [], "offlineHosts": []}

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(len(configured_nodes), 16)
    ) as executor:
        hosts = list(executor.map(check, configured_nodes))
    return {
        "port": WEBSERVER_PORT,
        "hosts": hosts,
        "offlineHosts": [host for host in hosts if not host["running"]],
    }


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


def influx_mtu_history():
    config = influx_config()
    rows = influx_query(f'''
from(bucket: "{escape_string(config["bucket"])}")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "tailmox_corosync_config")
  |> filter(fn: (r) => r._field == "configured_mtu" or r._field == "discovered_global_mtu" or r._field == "display_mtu" or r._field == "automatic" or r._field == "pmtud_interval_seconds" or r._field == "knet_ping_interval_ms" or r._field == "knet_ping_timeout_ms" or r._field == "token_ms" or r._field == "token_retransmit_ms" or r._field == "token_retransmits_before_loss" or r._field == "consensus_ms" or r._field == "max_network_delay_ms" or r._field == "max_messages" or r._field == "window_size" or r._field == "knet_compression_threshold" or r._field == "knet_compression_level")
  |> aggregateWindow(every: 1m, fn: last, createEmpty: false)
  |> sort(columns: ["_time"])
  |> limit(n: 120)
''')
    by_host = {}
    for row in rows:
        timestamp = influx_time(row.get("_time"))
        host = row.get("host")
        if timestamp is None or not host:
            continue
        samples = by_host.setdefault(host, {})
        sample = samples.setdefault(timestamp, {"timestamp": timestamp, "host": host})
        field = row.get("_field")
        if field == "configured_mtu":
            sample["configuredMtu"] = influx_int(row, "_value")
        elif field == "discovered_global_mtu":
            sample["discoveredGlobalMtu"] = influx_int(row, "_value")
        elif field == "display_mtu":
            sample["displayMtu"] = influx_int(row, "_value")
        elif field == "automatic":
            sample["automatic"] = influx_bool(row, "_value")
        elif field == "pmtud_interval_seconds":
            sample["pmtudIntervalSeconds"] = influx_int(row, "_value")
        elif field == "knet_ping_interval_ms":
            sample["knetPingIntervalMs"] = influx_int(row, "_value")
        elif field == "knet_ping_timeout_ms":
            sample["knetPingTimeoutMs"] = influx_int(row, "_value")
        elif field == "token_ms":
            sample["tokenMs"] = influx_int(row, "_value")
        elif field == "token_retransmit_ms":
            sample["tokenRetransmitMs"] = influx_int(row, "_value")
        elif field == "token_retransmits_before_loss":
            sample["tokenRetransmitsBeforeLoss"] = influx_int(row, "_value")
        elif field == "consensus_ms":
            sample["consensusMs"] = influx_int(row, "_value")
        elif field == "max_network_delay_ms":
            sample["maxNetworkDelayMs"] = influx_int(row, "_value")
        elif field == "max_messages":
            sample["maxMessages"] = influx_int(row, "_value")
        elif field == "window_size":
            sample["windowSize"] = influx_int(row, "_value")
        elif field == "knet_compression_threshold":
            sample["knetCompressionThreshold"] = influx_int(row, "_value")
        elif field == "knet_compression_level":
            sample["knetCompressionLevel"] = influx_int(row, "_value")
    return [
        {
            "name": host,
            "host": host,
            "samples": sorted(samples.values(), key=lambda sample: sample["timestamp"])[-720:],
        }
        for host, samples in sorted(by_host.items())
    ]


def collect_mtu_history():
    status = collect_mtu_status()
    series = influx_mtu_history()
    if not series:
        series = [{"name": socket.gethostname(), "host": socket.gethostname(), "samples": list(MTU_HISTORY)}]
    return {
        "generatedAt": status["generatedAt"],
        "current": status["current"],
        "history": list(MTU_HISTORY),
        "series": series,
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
    configured_nodes = collect_configured_nodes()
    member_health = corosync_member_health(configured_nodes, corosync_members, [])
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
    measured_nodeids = {link.get("nodeid") for link in LINK_QUALITY_CACHE["links"]}
    for link in LINK_QUALITY_CACHE["links"]:
        health = next((member for member in member_health if member.get("nodeid") == link.get("nodeid")), {})
        link["hostname"] = health.get("name") or peer_names.get(link.get("ip"), "")
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
    for member in member_health:
        if member.get("active") or member.get("nodeid") in measured_nodeids or member.get("ip") in local_ips:
            continue
        LINK_QUALITY_CACHE["links"].append(
            {
                "nodeid": member.get("nodeid"),
                "hostname": member.get("name") or peer_names.get(member.get("ip"), ""),
                "ip": member.get("ip"),
                "status": "offline",
                "quality": "offline",
                "packetLossPercent": None,
                "minMs": None,
                "avgMs": None,
                "maxMs": None,
                "jitterMs": None,
                "lastUpdatedAt": now,
                "raw": "",
            }
        )
    export_link_quality(LINK_QUALITY_CACHE["links"], now)
    return LINK_QUALITY_CACHE


def collect_link_quality_history():
    influx_history = influx_link_quality_history()
    if influx_history:
        return {
            "generatedAt": int(time.time()),
            "series": influx_history,
        }
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


def influx_test_history():
    config = influx_config()
    rows = influx_query(f'''
from(bucket: "{escape_string(config["bucket"])}")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "tailmox_icmp" or r._measurement == "tailmox_tcp")
  |> filter(fn: (r) => r._field == "average_ms" or r._field == "maximum_ms" or r._field == "latency_ms" or r._field == "packets_received" or r._field == "packets_sent")
  |> aggregateWindow(every: 1m, fn: last, createEmpty: false)
  |> sort(columns: ["_time"])
  |> limit(n: 120)
''')
    groups = {}
    for row in rows:
        timestamp = influx_time(row.get("_time"))
        if timestamp is None:
            continue
        measurement = row.get("_measurement")
        host = row.get("host")
        target = row.get("node") or f"port {row.get('port', 'unknown')}"
        if not host:
            continue
        key = (host, measurement, target)
        group = groups.setdefault(key, {"name": f"{host} → {target}", "host": host, "target": target, "kind": measurement, "samples": {}})
        sample = group["samples"].setdefault(timestamp, {"timestamp": timestamp})
        field = row.get("_field")
        value = influx_float(row, "_value")
        if field in ("average_ms", "latency_ms"):
            sample["avgMs"] = value
        elif field == "maximum_ms":
            sample["maxMs"] = value
        elif field == "packets_received":
            sample["received"] = influx_int(row, "_value")
        elif field == "packets_sent":
            sample["sent"] = influx_int(row, "_value")
    return [{**{name: value[name] for name in ("name", "host", "target", "kind")}, "samples": sorted(value["samples"].values(), key=lambda item: item["timestamp"])[-720:]}
            for key, value in sorted(groups.items())]


def collect_test_history():
    return {"generatedAt": int(time.time()), "series": influx_test_history()}


def influx_link_quality_history():
    config = influx_config()
    rows = influx_query(f'''
from(bucket: "{escape_string(config["bucket"])}")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "tailmox_corosync_link_quality")
  |> filter(fn: (r) => r._field == "packet_loss_percent" or r._field == "avg_ms" or r._field == "max_ms" or r._field == "jitter_ms")
  |> aggregateWindow(every: 1m, fn: last, createEmpty: false)
  |> sort(columns: ["_time"])
  |> limit(n: 120)
''')
    by_peer = {}
    for row in rows:
        timestamp = influx_time(row.get("_time"))
        if timestamp is None:
            continue
        host = row.get("host")
        peer_ip = row.get("peer_ip")
        peer_host = row.get("peer_host")
        peer_key = peer_ip or peer_host
        if not host or not peer_key:
            continue
        key = (host, peer_key)
        peer = by_peer.setdefault(key, {"host": host, "hostname": None, "samples": {}})
        if peer_host:
            peer["hostname"] = peer_host
        samples = peer["samples"]
        sample = samples.setdefault(
            timestamp,
            {
                "timestamp": timestamp,
                "hostname": peer_host,
                "ip": peer_ip,
            },
        )
        if peer_host:
            sample["hostname"] = peer_host
        field = row.get("_field")
        if field == "avg_ms":
            sample["avgMs"] = influx_float(row, "_value")
        elif field == "max_ms":
            sample["maxMs"] = influx_float(row, "_value")
        elif field == "jitter_ms":
            sample["jitterMs"] = influx_float(row, "_value")
        elif field == "packet_loss_percent":
            sample["packetLossPercent"] = influx_float(row, "_value")
    return [
        {
            "name": f"{peer['host']} → {peer['hostname'] or peer_key}",
            "host": peer["host"],
            "peer": peer["hostname"] or peer_key,
            "samples": sorted(peer["samples"].values(), key=lambda sample: sample["timestamp"])[-720:],
        }
        for (_, peer_key), peer in sorted(by_peer.items(), key=lambda item: (item[1]["host"], item[1]["hostname"] or item[0][1]))
    ]


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
    tailmox_state = collect_tailmox_state(configured_nodes)
    webservers = collect_webserver_health(configured_nodes)
    influx = collect_influx_health()

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
    healthy = (
        corosync_active
        and pve_cluster_active
        and quorate == "Yes"
        and not offline_members
        and not webservers["offlineHosts"]
        and (not influx["enabled"] or influx["online"])
    )
    member_count_sample = {
        "timestamp": int(time.time()),
        "memberCount": sum(1 for member in member_health if member.get("active")),
        "quorumNodeCount": len(quorum_nodes),
        "configuredNodeCount": len(configured_nodes),
        "offlineNodeCount": len(offline_members),
        "quorate": quorate == "Yes",
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
        "tailmox": tailmox_state,
        "webservers": webservers,
        "tailmoxUpdate": tailmox_update_status(),
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
        "influxdb": influx,
    }
    export_status(status)
    return status


def public_hostname(value):
    """Return a bounded hostname label, rejecting addresses and unsafe text."""
    if not isinstance(value, str) or not value.strip():
        return None
    label = value.strip().rstrip(".")
    if len(label) > 160 or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?", label):
        return None
    try:
        ipaddress.ip_address(label)
        return None
    except ValueError:
        return label


def public_graph_series(
    source, prefix, sample_fields, extra_fields=None, hostname_fields=(),
    label_fields=(),
):
    """Return bounded graph series with labels and allowlisted measurements."""
    extra_fields = extra_fields or {}
    sanitized = []
    source_series = source.get("series", []) if isinstance(source, dict) else []
    for item in source_series[:64]:
        samples = []
        for source_sample in item.get("samples", [])[-120:]:
            timestamp = source_sample.get("timestamp")
            if (
                not isinstance(timestamp, (int, float))
                or isinstance(timestamp, bool)
                or not math.isfinite(timestamp)
                or abs(timestamp) > PUBLIC_MAX_NUMBER
            ):
                continue
            sample = {"timestamp": timestamp}
            for field in sample_fields:
                value = source_sample.get(field)
                if field in PUBLIC_BOOLEAN_SAMPLE_FIELDS:
                    if isinstance(value, bool):
                        sample[field] = value
                    continue
                if (
                    isinstance(value, (int, float))
                    and not isinstance(value, bool)
                    and math.isfinite(value)
                    and abs(value) <= PUBLIC_MAX_NUMBER
                ):
                    sample[field] = value
            if len(sample) > 1:
                samples.append(sample)
        if not samples:
            continue
        labels = [public_hostname(item.get(field)) for field in label_fields]
        name = " → ".join(labels) if labels and all(labels) else None
        public_item = {
            "name": name or f"{prefix} {len(sanitized) + 1}",
            "samples": samples,
        }
        for destination, allowed_values in extra_fields.items():
            value = item.get(destination)
            if value in allowed_values:
                public_item[destination] = value
        for field in hostname_fields:
            value = public_hostname(item.get(field))
            if value:
                public_item[field] = value
        sanitized.append(public_item)
    return sanitized


def public_graphs(graph_sources):
    """Build the public graph schema through strict per-graph allowlists."""
    graph_sources = graph_sources or {}
    return {
        "mtu": {
            "series": public_graph_series(
                graph_sources.get("mtu", {}),
                "Node",
                (
                    "displayMtu", "configuredMtu", "discoveredGlobalMtu",
                    "automatic", "pmtudIntervalSeconds",
                ),
                label_fields=("host",),
            )
        },
        "members": {
            "series": public_graph_series(
                graph_sources.get("members", {}),
                "Node",
                (
                    "memberCount", "quorumNodeCount", "configuredNodeCount",
                    "offlineNodeCount", "quorate",
                ),
                label_fields=("host",),
            )
        },
        "linkQuality": {
            "series": public_graph_series(
                graph_sources.get("linkQuality", {}),
                "Link",
                ("avgMs", "maxMs", "jitterMs", "packetLossPercent"),
                hostname_fields=("host", "peer"),
                label_fields=("host", "peer"),
            )
        },
        "cmapKnet": {
            "series": public_graph_series(
                graph_sources.get("cmapKnet", {}),
                "Link",
                (
                    "latencyAvg", "latencyMax", "jitter", "txPacketDelta",
                    "rxPacketDelta", "errorDelta",
                ),
                label_fields=("host", "hostname"),
            )
        },
        "tests": {
            "series": public_graph_series(
                graph_sources.get("tests", {}),
                "Test",
                ("avgMs", "maxMs", "received", "sent"),
                {"kind": ("tailmox_icmp", "tailmox_tcp")},
                label_fields=("host", "target"),
            )
        },
    }


def public_link_quality_details(link_quality):
    """Expose current link measurements without IPs, node IDs, or raw output."""
    details = []
    for link in link_quality.get("links", [])[:64]:
        hostname = public_hostname(link.get("hostname")) or "unknown peer"
        item = {"hostname": hostname}
        for field in ("status", "quality"):
            value = link.get(field)
            if isinstance(value, str):
                item[field] = value[:32]
        for field in (
            "packetLossPercent", "avgMs", "maxMs", "jitterMs", "lastUpdatedAt",
        ):
            value = link.get(field)
            if (
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(value)
            ):
                item[field] = value
        details.append(item)
    return details


def public_snapshot(status, link_quality, graph_sources=None):
    """Return the deliberately small, non-identifying public status schema."""
    members = status.get("corosync", {}).get("members", [])
    links = link_quality.get("links", [])
    quality_counts = {"healthy": 0, "degraded": 0, "offline": 0, "unknown": 0}
    for link in links:
        quality = link.get("quality")
        if link.get("status") == "offline" or quality == "offline":
            quality_counts["offline"] += 1
        elif quality in ("loss", "jittery", "slow"):
            quality_counts["degraded"] += 1
        elif quality in ("good", "healthy"):
            quality_counts["healthy"] += 1
        else:
            quality_counts["unknown"] += 1

    webservers = status.get("webservers", {})
    webserver_hosts = webservers.get("hosts", [])
    influx = status.get("influxdb", {})
    generated_at = status.get("generatedAt")
    active_members = sum(1 for member in members if member.get("active"))
    configured_members = len(members)
    web_online = sum(1 for host in webserver_hosts if host.get("running"))
    web_total = len(webserver_hosts)
    sample = {
        "timestamp": generated_at,
        "activeMembers": active_members,
        "configuredMembers": configured_members,
        "healthyLinks": quality_counts["healthy"],
        "degradedLinks": quality_counts["degraded"],
        "offlineLinks": quality_counts["offline"],
        "webOnline": web_online,
        "webTotal": web_total,
    }
    if not PUBLIC_SNAPSHOT_HISTORY or PUBLIC_SNAPSHOT_HISTORY[-1].get("timestamp") != generated_at:
        PUBLIC_SNAPSHOT_HISTORY.append(sample)
        del PUBLIC_SNAPSHOT_HISTORY[:-PUBLIC_SNAPSHOT_HISTORY_LIMIT]

    return {
        "schemaVersion": 5,
        "generatedAt": status.get("generatedAt"),
        "monitorHostname": public_hostname(status.get("hostname")),
        "overall": status.get("overall") if status.get("overall") in ("healthy", "attention") else "unknown",
        "services": {
            "corosync": bool(status.get("services", {}).get("corosync", {}).get("active")),
            "proxmoxCluster": bool(status.get("services", {}).get("pveCluster", {}).get("active")),
            "tailscale": status.get("tailscale", {}).get("backendState") == "Running",
        },
        "cluster": {
            "quorate": status.get("cluster", {}).get("quorate") == "Yes",
            "activeMembers": active_members,
            "configuredMembers": configured_members,
            "offlineMembers": configured_members - active_members,
        },
        "links": quality_counts,
        "linkQualityDetails": public_link_quality_details(link_quality),
        "web": {
            "online": web_online,
            "total": web_total,
        },
        "metrics": {
            "configured": bool(influx.get("enabled")),
            "online": bool(influx.get("online")) if influx.get("enabled") else None,
        },
        "history": list(PUBLIC_SNAPSHOT_HISTORY),
        "graphs": public_graphs(graph_sources),
    }


def write_public_snapshot(path):
    destination = pathlib.Path(path)
    destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    status = collect_status()
    link_quality = collect_link_quality()
    graph_sources = {
        "mtu": collect_mtu_history(),
        "members": collect_member_count_history(),
        "linkQuality": collect_link_quality_history(),
        "cmapKnet": collect_cmap_knet_history(),
        "tests": collect_test_history(),
    }
    snapshot = public_snapshot(status, link_quality, graph_sources)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(snapshot, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def public_snapshot_worker(path):
    while True:
        try:
            write_public_snapshot(path)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"Unable to refresh public monitor snapshot: {error}", file=sys.stderr)
        time.sleep(PUBLIC_SNAPSHOT_INTERVAL_SECONDS)


def start_public_snapshot_exporter():
    if not PUBLIC_SNAPSHOT_FILE:
        return
    thread = threading.Thread(
        target=public_snapshot_worker, args=(PUBLIC_SNAPSHOT_FILE,), daemon=True
    )
    thread.start()


def collect_member_count_history():
    influx_series = influx_member_count_history()
    if influx_series:
        latest = max(
            (series["samples"][-1] for series in influx_series if series["samples"]),
            key=lambda sample: sample["timestamp"],
        )
        return {
            "generatedAt": int(time.time()),
            "current": latest,
            "history": [],
            "series": influx_series,
        }
    if not MEMBER_COUNT_HISTORY:
        status = collect_status()
        return {
            "generatedAt": status["generatedAt"],
            "current": status["corosync"]["memberCount"],
            "history": MEMBER_COUNT_HISTORY,
            "series": [{"name": socket.gethostname(), "host": socket.gethostname(), "samples": list(MEMBER_COUNT_HISTORY)}],
        }
    return {
        "generatedAt": int(time.time()),
        "current": MEMBER_COUNT_HISTORY[-1],
        "history": MEMBER_COUNT_HISTORY,
        "series": [{"name": socket.gethostname(), "host": socket.gethostname(), "samples": list(MEMBER_COUNT_HISTORY)}],
    }


def influx_member_count_history():
    config = influx_config()
    rows = influx_query(f'''
from(bucket: "{escape_string(config["bucket"])}")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "tailmox_cluster_status")
  |> filter(fn: (r) => r._field == "member_count" or r._field == "quorum_node_count" or r._field == "configured_node_count" or r._field == "offline_node_count" or r._field == "quorate")
  |> aggregateWindow(every: 1m, fn: last, createEmpty: false)
  |> sort(columns: ["_time"])
  |> limit(n: 120)
''')
    by_host = {}
    for row in rows:
        timestamp = influx_time(row.get("_time"))
        host = row.get("host")
        if timestamp is None or not host:
            continue
        samples = by_host.setdefault(host, {})
        sample = samples.setdefault(timestamp, {"timestamp": timestamp, "host": host})
        field = row.get("_field")
        if field == "member_count":
            sample["memberCount"] = influx_int(row, "_value")
        elif field == "quorum_node_count":
            sample["quorumNodeCount"] = influx_int(row, "_value")
        elif field == "configured_node_count":
            sample["configuredNodeCount"] = influx_int(row, "_value")
        elif field == "offline_node_count":
            sample["offlineNodeCount"] = influx_int(row, "_value")
        elif field == "quorate":
            sample["quorate"] = influx_bool(row, "_value")
    return [
        {
            "name": host,
            "host": host,
            "samples": [
                sample
                for sample in sorted(samples.values(), key=lambda sample: sample["timestamp"])
                if sample.get("memberCount") is not None
            ][-720:],
        }
        for host, samples in sorted(by_host.items())
    ]


def collect_cmap_knet_history():
    return {
        "generatedAt": int(time.time()),
        "series": influx_cmap_knet_history(),
    }


def influx_cmap_knet_history():
    config = influx_config()
    current_members = collect_corosync_members()
    active_nodeids = {
        member.get("nodeid")
        for member in current_members
        if member.get("nodeid") and member.get("status") == "joined"
    }
    node_names = {
        node.get("nodeid"): node.get("name")
        for node in collect_configured_nodes()
        if node.get("nodeid") and node.get("name")
    }
    rows = influx_query(f'''
from(bucket: "{escape_string(config["bucket"])}")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "tailmox_corosync_cmap_stat")
  |> filter(fn: (r) => r.family == "knet")
  |> filter(fn: (r) => exists r.nodeid and exists r.link and exists r.metric)
  |> filter(fn: (r) => r._field == "value")
  |> filter(fn: (r) => r.metric == "latency_ave" or r.metric == "latency_max" or r.metric == "tx_data_packets" or r.metric == "rx_data_packets" or r.metric =~ /.*error.*/)
  |> aggregateWindow(every: 1m, fn: last, createEmpty: false)
  |> sort(columns: ["_time"])
  |> limit(n: 120)
''', timeout=12)
    by_link = {}
    for row in rows:
        timestamp = influx_time(row.get("_time"))
        value = influx_float(row, "_value")
        nodeid = row.get("nodeid")
        link = row.get("link")
        metric = row.get("metric")
        host = row.get("host")
        if timestamp is None or value is None or not host or not nodeid or not link or not metric:
            continue
        if active_nodeids and nodeid not in active_nodeids:
            continue
        if node_names.get(nodeid) == host:
            continue
        key = (host, nodeid, link)
        series = by_link.setdefault(
            key,
            {
                "name": f"{host} → {node_names.get(nodeid, f'node {nodeid}')} link {link}",
                "host": host,
                "hostname": node_names.get(nodeid),
                "nodeid": nodeid,
                "link": link,
                "samples": {},
            },
        )
        sample = series["samples"].setdefault(timestamp, {"timestamp": timestamp})
        if metric == "latency_ave":
            sample["latencyAvg"] = value
        elif metric == "latency_max":
            sample["latencyMax"] = value
        elif metric == "tx_data_packets":
            sample["txPackets"] = value
        elif metric == "rx_data_packets":
            sample["rxPackets"] = value
        elif "error" in metric:
            sample["errors"] = sample.get("errors", 0) + value

    series_values = []
    for item in by_link.values():
        samples = sorted(item["samples"].values(), key=lambda sample: sample["timestamp"])[-720:]
        previous_latency = None
        previous_tx = None
        previous_rx = None
        previous_errors = None
        for sample in samples:
            latency = sample.get("latencyAvg")
            if latency is not None and previous_latency is not None:
                sample["jitter"] = abs(latency - previous_latency)
            elif latency is not None:
                sample["jitter"] = 0
            if latency is not None:
                previous_latency = latency

            tx_packets = sample.get("txPackets")
            if tx_packets is not None and previous_tx is not None:
                sample["txPacketDelta"] = max(0, tx_packets - previous_tx)
            if tx_packets is not None:
                previous_tx = tx_packets

            rx_packets = sample.get("rxPackets")
            if rx_packets is not None and previous_rx is not None:
                sample["rxPacketDelta"] = max(0, rx_packets - previous_rx)
            if rx_packets is not None:
                previous_rx = rx_packets

            errors = sample.get("errors")
            if errors is not None and previous_errors is not None:
                sample["errorDelta"] = max(0, errors - previous_errors)
            if errors is not None:
                previous_errors = errors
        item["samples"] = samples
        series_values.append(item)
    return sorted(series_values, key=lambda item: (item["host"], int_or_none(item["nodeid"]) or 0, int_or_none(item["link"]) or 0))


HEALTH_HTML = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tailmox Health</title><style>
:root{color-scheme:dark;--line:#334155;--text:#e5e7eb;--muted:#9ca3af}body{margin:0;min-height:100vh;color:var(--text);font:16px system-ui,sans-serif;background:linear-gradient(135deg,#0b1020,#14213d)}main{max-width:760px;margin:auto;padding:clamp(24px,7vw,64px) 20px}header{display:flex;justify-content:space-between;gap:16px;align-items:start;margin-bottom:28px}h1{margin:0 0 6px;font-size:32px}p{color:var(--muted);margin:0}.pill{border:1px solid var(--line);border-radius:999px;padding:8px 12px;font-weight:700;white-space:nowrap}.good{color:#bbf7d0;border-color:#347b51;background:#14532d55}.warn{color:#fde68a;border-color:#8a641f;background:#78350f55}.bad{color:#fecdd3;border-color:#8f3042;background:#7f1d1d55}.issues{display:grid;gap:10px}.check{padding:17px 18px;border:1px solid var(--line);border-left:4px solid #f59e0b;border-radius:10px;background:#111827dd}.check.bad{border-left-color:#ef4444}.check.pass{border-color:#347b51;border-left-color:#22c55e;background:#14532d33}.check strong{display:block;margin-bottom:4px}.check.pass strong{color:#bbf7d0}a{color:#7dd3fc;display:inline-block;margin-top:24px}label{color:var(--muted);font-size:13px}select{margin-left:4px;padding:7px;border:1px solid #38bdf86b;border-radius:7px;color:#f8fafc;background:#0f172a;cursor:pointer;box-shadow:0 4px 14px #0206173d}select:hover{border-color:#38bdf8b8;background:#172033}select:focus{outline:2px solid #38bdf857;outline-offset:2px;border-color:#38bdf8}select option{color:#f8fafc;background:#0f172a;font-weight:600}select option:checked{color:#ecfeff;background:#155e75}@media(max-width:540px){header{display:block}.pill{display:inline-block;margin-top:15px}}
</style></head><body><main><header><div><h1>Tailmox Monitor</h1><p>Cluster health at a glance</p></div><div><label>Page <select id="page"><option value="health">Health</option><option value="monitor">Monitor</option><option value="settings">Settings</option><option value="id">ID</option><option value="disable">Disable Tailmox</option></select></label><div class="pill" id="overall">Checking…</div></div></header><section><h2>Cluster health</h2><p id="updated">Checking current status…</p></section><section class="issues" id="issues"><div class="check">Loading health checks…</div></section><a href="/">Open detailed monitor</a></main><script>
const apiPrefix=(window.location.pathname==="/monitor/health"||window.location.pathname.startsWith("/monitor/"))?"/monitor":"";document.querySelector("a").href=`${apiPrefix}/`;document.getElementById("page").addEventListener("change",event=>{const target=event.target.value;window.location.href=target==="health"?`${apiPrefix}/health`:target==="monitor"?`${apiPrefix}/`:`${apiPrefix}/${target}`});const issues=document.getElementById("issues"),overall=document.getElementById("overall"),add=(title,detail,state="warn")=>{const item=document.createElement("div"),heading=document.createElement("strong"),description=document.createElement("span");item.className=`check ${state}`;heading.textContent=title;description.textContent=detail;item.append(heading,description);issues.append(item)};
async function load(){try{const [sr,lr]=await Promise.all([fetch(`${apiPrefix}/api/status`,{cache:"no-store"}),fetch(`${apiPrefix}/api/link-quality`,{cache:"no-store"})]),data=await sr.json(),links=await lr.json();if(!sr.ok)throw Error(data.error||"Unable to read cluster status.");issues.replaceChildren();if(data.services?.corosync?.active)add("Corosync is online","The cluster communication service is active.","pass");else add("Corosync is offline","The cluster communication service is not active.","bad");if(data.services?.pveCluster?.active)add("Proxmox cluster service is online","The pve-cluster service is active.","pass");else add("Proxmox cluster service is offline","The pve-cluster service is not active.","bad");if(data.influxdb?.enabled){if(data.influxdb?.online)add("InfluxDB is online",data.influxdb.detail||"The configured InfluxDB health endpoint responded.","pass");else add("InfluxDB is offline",data.influxdb.detail||"The configured InfluxDB health endpoint did not respond.","bad")}const offline=data.corosync?.offlineMembers||[];if(offline.length)add(`${offline.length} host${offline.length===1?" is":"s are"} offline`,offline.map(m=>m.name||m.ip||`node ${m.nodeid}`).join(", "),data.cluster?.quorate!=="Yes"?"bad":"warn");else add("All cluster hosts are online",`${data.corosync?.members?.length||0} configured host${data.corosync?.members?.length===1?" is":"s are"} active.`,"pass");const missingWebservers=data.webservers?.offlineHosts||[];if(missingWebservers.length)add(`${missingWebservers.length} host${missingWebservers.length===1?" is":"s are"} not running the port ${data.webservers?.port||8088} webserver`,missingWebservers.map(host=>host.name||host.host||`node ${host.nodeid}`).join(", "),"bad");else add("Tailmox webservers are online",`${data.webservers?.hosts?.length||0} configured host${data.webservers?.hosts?.length===1?" is":"s are"} accepting connections on port ${data.webservers?.port||8088}.`,"pass");if(data.cluster?.quorate==="Yes")add("Cluster has quorum","Cluster operations can proceed safely.","pass");else add("Cluster has no quorum","Cluster operations may be unsafe until quorum is restored.","bad");for(const link of(links.links||[])){const peer=link.hostname||link.ip||"peer";if(link.quality==="loss")add(`Packet loss to ${peer}`,`${link.packetLossPercent??"unknown"}% packet loss.`);else if(link.quality==="jittery")add(`High jitter to ${peer}`,`${(link.jitterMs??0).toFixed(1)} ms jitter.`);else if(link.quality==="slow")add(`High latency to ${peer}`,`${(link.avgMs??0).toFixed(1)} ms average latency.`);else if(link.quality==="unknown")add(`Link quality unavailable for ${peer}`,"The peer could not be measured.","bad");else add(`Link to ${peer} is healthy`,`${(link.avgMs??0).toFixed(1)} ms average latency with no packet loss.`,"pass")}const attention=issues.querySelector(".check:not(.pass)"),failure=issues.querySelector(".check.bad");overall.textContent=attention?"Needs attention":"Healthy";overall.className=`pill ${failure?"bad":attention?"warn":"good"}`;document.getElementById("updated").textContent=`${data.hostname||"Host"} · updated ${new Date(data.generatedAt*1000).toLocaleString()}`}catch(error){issues.replaceChildren();add("Health check unavailable",error.message,"bad");overall.textContent="Unavailable";overall.className="pill bad"}}load();setInterval(load,30000);
</script></body></html>
"""

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
    header { display: flex; justify-content: space-between; align-items: center; gap: 20px; margin-bottom: 24px; }
    h1 { font-size: 30px; margin: 0 0 6px; color: #f8fafc; }
    h2 { font-size: 15px; margin: 0 0 14px; color: var(--muted); font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; }
    .muted { color: var(--muted); }
    .grid { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 14px; }
    .wide { grid-column: span 2; }
    .wide-primary { grid-column: span 3; }
    .full { grid-column: 1 / -1; }
    .panel { position: relative; overflow: hidden; border: 1px solid rgba(148,163,184,0.28); border-radius: 8px; padding: 16px; background: linear-gradient(180deg, rgba(17,24,39,0.94), rgba(15,23,42,0.94)); box-shadow: 0 14px 34px rgba(0,0,0,0.24); }
    .panel::before { content: ""; position: absolute; inset: 0 0 auto; height: 4px; background: rgba(148,163,184,0.36); }
    .panel.status-good::before { background: var(--good); box-shadow: 0 0 20px rgba(34,197,94,0.32); }
    .panel.status-warn::before { background: var(--warn); box-shadow: 0 0 20px rgba(245,158,11,0.32); }
    .panel.status-bad::before { background: var(--bad); box-shadow: 0 0 20px rgba(239,68,68,0.32); }
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
    .summary-chips { display: flex; flex-wrap: wrap; gap: 8px; margin: -2px 0 12px; color: var(--muted); }
    .summary-chip { display: inline-flex; align-items: baseline; gap: 6px; border: 1px solid rgba(148,163,184,0.24); border-radius: 8px; padding: 7px 10px; background: rgba(2,6,23,0.24); }
    .summary-chip strong { color: #f8fafc; font-size: 15px; }
    .summary-chip span { font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.04em; }
    .summary-chip.good { border-color: rgba(34,197,94,0.36); background: rgba(20,83,45,0.18); }
    .summary-chip.good strong, .summary-chip.good span { color: #bbf7d0; }
    .summary-chip.warn { border-color: rgba(245,158,11,0.42); background: rgba(120,53,15,0.18); }
    .summary-chip.warn strong, .summary-chip.warn span { color: #fde68a; }
    .summary-chip.bad { border-color: rgba(244,63,94,0.42); background: rgba(127,29,29,0.18); }
    .summary-chip.bad strong, .summary-chip.bad span { color: #fecdd3; }
    .metric-cell { border-radius: 6px; padding: 4px 8px; font-weight: 800; }
    .metric-cell.good { color: #bbf7d0; background: rgba(34,197,94,0.12); }
    .metric-cell.warn { color: #fde68a; background: rgba(245,158,11,0.14); }
    .metric-cell.bad { color: #fecdd3; background: rgba(244,63,94,0.14); }
    .loading { display: inline-flex; align-items: center; gap: 10px; color: var(--muted); }
    .spinner { width: 16px; height: 16px; border: 2px solid rgba(148,163,184,0.28); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .actions { display: flex; gap: 14px; align-items: end; flex-wrap: wrap; }
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
    .chart .chart-point { cursor: crosshair; stroke: rgba(248,250,252,0.82); stroke-width: 1; }
    .chart .chart-point:hover, .chart .chart-point:focus { stroke: #f8fafc; stroke-width: 2; }
    .chart-loading-track { fill: none; stroke: rgba(148,163,184,0.22); stroke-width: 5; }
    .chart-loading-indicator { fill: none; stroke: var(--accent); stroke-width: 5; stroke-linecap: round; stroke-dasharray: 58 42; transform-box: fill-box; transform-origin: center; animation: spin 0.8s linear infinite; }
    .chart-tooltip { position: fixed; z-index: 20; max-width: 270px; padding: 10px 12px; border: 1px solid rgba(148,163,184,0.32); border-radius: 8px; color: #e5e7eb; background: rgba(15,23,42,0.96); box-shadow: 0 18px 50px rgba(2,6,23,0.36); font-size: 12px; line-height: 1.45; white-space: pre-line; pointer-events: none; transform: translate(12px, -50%); opacity: 0; transition: opacity 0.12s ease; }
    .chart-tooltip.visible { opacity: 1; }
    .legend { display: flex; flex-wrap: wrap; gap: 8px 14px; margin-top: 10px; color: var(--muted); font-size: 13px; }
    .legend-item { display: inline-flex; align-items: center; gap: 7px; }
    .swatch { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
    pre { white-space: pre-wrap; overflow: auto; margin: 0; color: #cbd5e1; font-size: 13px; line-height: 1.45; background: rgba(2,6,23,0.42); border-radius: 6px; padding: 12px; }
    .log-line { display: block; padding: 1px 0; }
    .log-error { color: #fecdd3; }
    .log-warn { color: #fde68a; }
    .log-good { color: #bbf7d0; }
    .log-knet { color: #bae6fd; }
    .log-quorum { color: #ddd6fe; }
    .log-totem { color: #99f6e4; }
    .test-line { display: block; padding: 1px 0; }
    .test-pass { color: #bbf7d0; }
    .test-fail { color: #fecdd3; font-weight: 800; }
    .test-section { color: #bae6fd; font-weight: 800; }
    .test-summary { color: #fde68a; font-weight: 800; }
    @media (max-width: 850px) { main { padding: 18px; } header { display: block; } .grid { grid-template-columns: 1fr; } .wide, .wide-primary { grid-column: auto; } #linkQualityChart { height: 160px; } .link-quality-table { table-layout: fixed; font-size: 11px; } .link-quality-table th, .link-quality-table td { padding: 6px 3px; overflow-wrap: anywhere; } .link-quality-table .tag { padding: 2px 4px; font-size: 10px; } .link-quality-table .metric-cell { padding: 3px 4px; } .link-quality-table th:nth-child(2), .link-quality-table td:nth-child(2), .link-quality-table th:nth-child(3), .link-quality-table td:nth-child(3), .link-quality-table th:nth-child(9), .link-quality-table td:nth-child(9) { display: none; } }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Tailmox Monitor</h1>
        <div class="muted" id="subtitle">Loading cluster health...</div>
      </div>
      <div class="actions">
        <div class="pill" id="overall"><span class="dot"></span><span>Loading</span></div>
      </div>
    </header>
    <section class="grid">
      <div class="panel" id="tailmoxPanel"><h2>Tailmox</h2><div class="metric" id="tailmoxState">...</div><div class="muted" id="tailmoxDetail"></div></div>
      <div class="panel" id="corosyncPanel"><h2>Corosync</h2><div class="metric" id="corosyncState">...</div><div class="muted" id="corosyncEnabled"></div></div>
      <div class="panel" id="quorumPanel"><h2>Quorum</h2><div class="metric" id="quorumState">...</div><div class="muted" id="votes"></div></div>
      <div class="panel" id="clusterPanel"><h2>Cluster</h2><div class="metric" id="clusterName">...</div><div class="muted" id="transport"></div></div>
      <div class="panel" id="tailscalePanel"><h2>Tailscale</h2><div class="metric" id="tailscaleState">...</div><div class="muted" id="tailscaleName"></div></div>
      <div class="panel" id="influxPanel"><h2>InfluxDB</h2><div class="metric" id="influxState">...</div><div class="muted" id="influxDetail"></div></div>
      <div class="panel wide-primary"><h2>Corosync Members</h2><table><thead><tr><th>Node</th><th>Peer IP</th><th>ID</th><th>Votes</th><th>Status</th></tr></thead><tbody id="members"></tbody></table></div>
      <div class="panel wide"><h2>Quorum Nodes</h2><table><thead><tr><th>Node</th><th>ID</th><th>Votes</th><th>Local</th></tr></thead><tbody id="quorumNodes"></tbody></table></div>
      <div class="panel full"><h2>Global MTU by Host (last hour)</h2><div class="muted" id="mtuDetail"></div><svg class="chart" id="mtuChart" viewBox="0 0 900 220" role="img" aria-label="Global MTU by host over the last hour"><circle class="chart-loading-track" cx="450" cy="110" r="17"></circle><circle class="chart-loading-indicator" cx="450" cy="110" r="17" pathLength="100"></circle></svg><div class="legend" id="mtuLegend"></div></div>
      <div class="panel full"><h2>Cluster Members by Host (last hour)</h2><div class="muted" id="memberCountDetail"></div><svg class="chart" id="memberCountChart" viewBox="0 0 900 220" role="img" aria-label="Cluster members reported by each host over the last hour"><circle class="chart-loading-track" cx="450" cy="110" r="17"></circle><circle class="chart-loading-indicator" cx="450" cy="110" r="17" pathLength="100"></circle></svg><div class="legend" id="memberCountLegend"></div></div>
      <div class="panel full"><h2>Link Quality (last hour)</h2><div class="muted" id="linkQualityGraphDetail"></div><svg class="chart" id="linkQualityChart" viewBox="0 0 900 220" role="img" aria-label="Link quality over the last hour"><circle class="chart-loading-track" cx="450" cy="110" r="17"></circle><circle class="chart-loading-indicator" cx="450" cy="110" r="17" pathLength="100"></circle></svg><div class="legend" id="linkQualityLegend"></div></div>
      <div class="panel full"><h2>Corosync Knet Latency and Jitter (last hour, microseconds)</h2><div class="muted" id="cmapLatencyDetail"></div><svg class="chart" id="cmapLatencyChart" viewBox="0 0 900 220" role="img" aria-label="Corosync Knet average latency over the last hour in microseconds"><circle class="chart-loading-track" cx="450" cy="110" r="17"></circle><circle class="chart-loading-indicator" cx="450" cy="110" r="17" pathLength="100"></circle></svg><div class="legend" id="cmapLatencyLegend"></div></div>
      <div class="panel full"><h2>Corosync Knet Packets and Errors (last hour, count per minute)</h2><div class="muted" id="cmapPacketDetail"></div><svg class="chart" id="cmapPacketChart" viewBox="0 0 900 220" role="img" aria-label="Corosync Knet packet and error count per minute over the last hour"><circle class="chart-loading-track" cx="450" cy="110" r="17"></circle><circle class="chart-loading-indicator" cx="450" cy="110" r="17" pathLength="100"></circle></svg><div class="legend" id="cmapPacketLegend"></div></div>
      <div class="panel full"><h2>Tailmox Test Latency (last hour)</h2><div class="muted" id="testHistoryDetail"></div><svg class="chart" id="testHistoryChart" viewBox="0 0 900 220" role="img" aria-label="Tailmox test latency over the last hour"><circle class="chart-loading-track" cx="450" cy="110" r="17"></circle><circle class="chart-loading-indicator" cx="450" cy="110" r="17" pathLength="100"></circle></svg><div class="legend" id="testHistoryLegend"></div></div>
      <div class="panel full"><h2>Corosync Link Quality</h2><table class="link-quality-table"><thead><tr><th>Hostname</th><th>Peer IP</th><th>Status</th><th>Loss</th><th>Avg</th><th>Max</th><th>Jitter</th><th>Quality</th><th>Last updated</th></tr></thead><tbody id="linkQuality"></tbody></table></div>
      <div class="panel full"><h2>Recent Corosync Logs</h2><pre id="logs">Loading...</pre></div>
      <div class="panel full"><h2>Raw Cluster Status</h2><pre id="raw"></pre></div>
    </section>
  </main>
  <div class="chart-tooltip" id="chartTooltip"></div>
  <script>
    const apiPrefix = (window.location.pathname === "/monitor" || window.location.pathname.startsWith("/monitor/")) ? "/monitor" : (window.location.pathname === "/control" || window.location.pathname.startsWith("/control/") ? "/control" : "");
    const text = (id, value) => document.getElementById(id).textContent = value || "unknown";
    const setPanelStatus = (id, status) => {
      const panel = document.getElementById(id);
      panel.classList.remove("status-good", "status-warn", "status-bad");
      panel.classList.add(`status-${status}`);
    };
    const yesNo = value => value ? "active" : "inactive";
    const ms = value => Number.isFinite(value) ? `${value.toFixed(1)} ms` : "unknown";
    const percent = value => Number.isFinite(value) ? `${value.toFixed(1)}%` : "unknown";
    const localTime = value => Number.isFinite(value) ? new Date(value * 1000).toLocaleTimeString() : "unknown";
    const qualityClass = (value, warn, bad) => !Number.isFinite(value) ? "bad" : value >= bad ? "bad" : value >= warn ? "warn" : "good";
    const metricCell = (value, text, warn, bad) => `<span class="metric-cell ${qualityClass(value, warn, bad)}">${text}</span>`;
    const number = value => Number.isFinite(value) ? value.toLocaleString() : "auto";
    const detailChips = (id, chips) => {
      document.getElementById(id).className = "summary-chips";
      document.getElementById(id).innerHTML = chips.map(chip => `<span class="summary-chip ${chip.status || ""}"><strong>${escapeHtml(chip.value)}</strong><span>${escapeHtml(chip.label)}</span></span>`).join("");
    };
    const timeLabel = value => new Date(value * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" });
    const dateTimeLabel = value => Number.isFinite(value) ? new Date(value * 1000).toLocaleString() : "unknown";
    const seriesColors = ["#38bdf8", "#2dd4bf", "#a78bfa", "#fb7185", "#f59e0b", "#22c55e", "#e879f9", "#60a5fa"];
    const svg = (name, attrs = {}, content = "") => `<${name} ${Object.entries(attrs).map(([key, value]) => `${key}="${value}"`).join(" ")}>${content}</${name}>`;
    const escapeHtml = value => String(value).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
    const tooltipText = lines => escapeHtml(lines.filter(line => line !== null && line !== undefined && line !== "").join("\\n"));
    const hideChartTooltip = () => document.getElementById("chartTooltip").classList.remove("visible");
    const moveChartTooltip = event => {
      const tooltip = document.getElementById("chartTooltip");
      const padding = 16;
      const rect = tooltip.getBoundingClientRect();
      const targetRect = event.target.getBoundingClientRect();
      const pointerX = Number.isFinite(event.clientX) ? event.clientX : targetRect.left + targetRect.width / 2;
      const pointerY = Number.isFinite(event.clientY) ? event.clientY : targetRect.top + targetRect.height / 2;
      const x = Math.min(pointerX + 12, window.innerWidth - rect.width - padding);
      const y = Math.max(padding, Math.min(pointerY, window.innerHeight - rect.height - padding));
      tooltip.style.left = `${x}px`;
      tooltip.style.top = `${y}px`;
    };
    const showChartTooltip = event => {
      const detail = event.target.dataset.tooltip;
      if (!detail) return;
      const tooltip = document.getElementById("chartTooltip");
      tooltip.innerHTML = detail;
      moveChartTooltip(event);
      tooltip.classList.add("visible");
    };
    const attachChartTooltips = chart => {
      chart.querySelectorAll("[data-tooltip]").forEach(point => {
        point.setAttribute("tabindex", "0");
        point.addEventListener("mouseenter", showChartTooltip);
        point.addEventListener("mousemove", moveChartTooltip);
        point.addEventListener("mouseleave", hideChartTooltip);
        point.addEventListener("focus", showChartTooltip);
        point.addEventListener("blur", hideChartTooltip);
      });
    };
    const logClass = line => {
      const lower = line.toLowerCase();
      if (lower.includes("failed") || lower.includes("error") || lower.includes("has no active links")) return "log-error";
      if (lower.includes("timed out") || lower.includes("timeout") || lower.includes("down") || lower.includes("retransmit")) return "log-warn";
      if (lower.includes("joined") || lower.includes("is up") || lower.includes("ready to provide service")) return "log-good";
      if (line.includes("[KNET")) return "log-knet";
      if (line.includes("[QUORUM")) return "log-quorum";
      if (line.includes("[TOTEM")) return "log-totem";
      return "";
    };
    const renderLogs = lines => {
      document.getElementById("logs").innerHTML = (lines || []).map(line => `<span class="log-line ${logClass(line)}">${escapeHtml(line)}</span>`).join("") || "No recent corosync logs available.";
    };
    const renderLineChart = (chart, history, valueKey, emptyText, formatLabel = number, tooltipFormatter = null) => {
      if (!history.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, emptyText);
        hideChartTooltip();
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
        history.map(sample => svg("circle", { class: "point chart-point", cx: x(sample).toFixed(1), cy: y(sample).toFixed(1), r: 4, "data-tooltip": tooltipFormatter ? tooltipText(tooltipFormatter(sample)) : tooltipText([dateTimeLabel(sample.timestamp), `${valueKey}: ${formatLabel(sample[valueKey])}`]) })).join(""),
      ].join("");
      attachChartTooltips(chart);
    };
    const renderLinkQuality = links => {
      document.getElementById("linkQuality").innerHTML = (links || []).map(link => `<tr><td>${escapeHtml(link.hostname || "unknown")}</td><td>${escapeHtml(link.ip || "")}</td><td><span class="tag ${link.status === "offline" ? "offline" : "joined"}">${escapeHtml(link.status || "unknown")}</span></td><td>${metricCell(link.packetLossPercent, percent(link.packetLossPercent), 0.1, 1)}</td><td>${metricCell(link.avgMs, ms(link.avgMs), 50, 150)}</td><td>${metricCell(link.maxMs, ms(link.maxMs), 100, 250)}</td><td>${metricCell(link.jitterMs, ms(link.jitterMs), 10, 20)}</td><td><span class="tag ${escapeHtml(link.quality || "unknown")}">${escapeHtml(link.quality || "unknown")}</span></td><td>${localTime(link.lastUpdatedAt)}</td></tr>`).join("") || "<tr><td colspan='9'>No remote corosync links measured</td></tr>";
    };
    const memberSampleColor = sample => {
      if (sample.quorate === false) return "#ef4444";
      if (Number.isFinite(sample.offlineNodeCount) && sample.offlineNodeCount > 0) return "#f59e0b";
      if (Number.isFinite(sample.configuredNodeCount) && Number.isFinite(sample.memberCount) && sample.memberCount < sample.configuredNodeCount) return "#f59e0b";
      return "#22c55e";
    };
    const renderMemberCountChart = (chart, history) => {
      if (!history.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, "No member-count samples collected yet.");
        hideChartTooltip();
        return;
      }
      const width = 900, height = 220, left = 58, right = 20, top = 20, bottom = 38;
      const minTime = history[0].timestamp;
      const maxTime = history[history.length - 1].timestamp || minTime + 1;
      const values = history.map(sample => sample.memberCount);
      const minValue = Math.min(...values);
      const maxValue = Math.max(...values);
      const flat = minValue === maxValue;
      const padding = flat ? Math.max(1, Math.round(maxValue * 0.05)) : 0;
      const chartMin = Math.max(0, minValue - padding);
      const chartMax = maxValue + padding;
      const span = Math.max(1, chartMax - chartMin);
      const x = sample => left + ((sample.timestamp - minTime) / Math.max(1, maxTime - minTime)) * (width - left - right);
      const y = sample => top + (1 - ((sample.memberCount - chartMin) / span)) * (height - top - bottom);
      const midValue = chartMin + span / 2;
      const segments = history.length === 1
        ? ""
        : history.slice(1).map((sample, index) => {
            const previous = history[index];
            return `<line x1="${x(previous).toFixed(1)}" y1="${y(previous).toFixed(1)}" x2="${x(sample).toFixed(1)}" y2="${y(sample).toFixed(1)}" stroke="${memberSampleColor(sample)}" stroke-width="3" stroke-linecap="round"></line>`;
          }).join("");
      chart.innerHTML = [
        svg("line", { class: "grid-line", x1: left, y1: top, x2: left, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: height - bottom, x2: width - right, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: top, x2: width - right, y2: top }),
        svg("text", { x: 10, y: top + 4 }, number(chartMax)),
        svg("text", { x: 10, y: y({ memberCount: midValue }) + 4 }, number(Math.round(midValue))),
        svg("text", { x: 10, y: height - bottom + 4 }, number(chartMin)),
        svg("text", { x: left, y: height - 12 }, timeLabel(minTime)),
        svg("text", { x: width / 2 - 34, y: height - 12 }, timeLabel(minTime + (maxTime - minTime) / 2)),
        svg("text", { x: width - right - 72, y: height - 12 }, timeLabel(maxTime)),
        segments,
        history.map(sample => svg("circle", {
          class: "chart-point",
          cx: x(sample).toFixed(1),
          cy: y(sample).toFixed(1),
          r: 4,
          fill: memberSampleColor(sample),
          "data-tooltip": tooltipText([
            dateTimeLabel(sample.timestamp),
            `Members online: ${number(sample.memberCount)}`,
            `Configured hosts: ${number(sample.configuredNodeCount)}`,
            `Offline hosts: ${number(sample.offlineNodeCount)}`,
            `Quorum nodes: ${number(sample.quorumNodeCount)}`,
            `Quorate: ${sample.quorate === false ? "no" : "yes"}`,
          ]),
        })).join(""),
      ].join("");
      attachChartTooltips(chart);
    };
    const renderMtu = data => {
      const series = data.series || [{ name: latestStatus?.hostname || "local host", samples: data.history || [] }];
      const result = renderCmapSeriesChart(document.getElementById("mtuChart"), document.getElementById("mtuLegend"), series, "displayMtu", {
        label: "Displayed MTU", axisLabel: "bytes", format: number, emptyText: "No global MTU samples collected yet.",
        tooltip: (item, sample) => [
          `Configured MTU: ${sample.automatic ? "auto" : `${number(sample.configuredMtu)} bytes`}`,
          `Discovered global MTU: ${Number.isFinite(sample.discoveredGlobalMtu) ? `${number(sample.discoveredGlobalMtu)} bytes` : "unknown"}`,
          `PMTUD interval: ${Number.isFinite(sample.pmtudIntervalSeconds) ? `${number(sample.pmtudIntervalSeconds)}s` : "unknown"}`,
        ],
      });
      detailChips("mtuDetail", [
        { value: number(result.seriesCount), label: "hosts" },
        { value: number(result.sampleCount), label: "samples" },
        { value: "1h", label: "window" },
      ]);
    };
    const renderMemberCount = data => {
      const series = data.series || [{ name: latestStatus?.hostname || "local host", samples: data.history || [] }];
      const latest = series.map(item => (item.samples || [])[item.samples.length - 1]).filter(Boolean);
      const issueHosts = latest.filter(sample => sample.quorate === false || (sample.offlineNodeCount || 0) > 0).length;
      const result = renderCmapSeriesChart(document.getElementById("memberCountChart"), document.getElementById("memberCountLegend"), series, "memberCount", {
        label: "Members online", axisLabel: "hosts", format: number, emptyText: "No member-count samples collected yet.", pointColor: memberSampleColor,
        tooltip: (item, sample) => [
          `Configured hosts: ${number(sample.configuredNodeCount)}`,
          `Offline hosts: ${number(sample.offlineNodeCount)}`,
          `Quorum nodes: ${number(sample.quorumNodeCount)}`,
          `Quorate: ${sample.quorate === false ? "no" : "yes"}`,
        ],
      });
      detailChips("memberCountDetail", [
        { value: number(result.seriesCount), label: "reporting hosts" },
        { value: number(issueHosts), label: "hosts reporting issues", status: issueHosts ? "warn" : "good" },
        { value: number(result.sampleCount), label: "samples" },
      ]);
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
      detailChips("linkQualityGraphDetail", [
        { value: number(series.length), label: "host-to-peer paths" },
        { value: number(totalSamples), label: "samples" },
        { value: "average", label: "latency metric" },
      ]);
      legend.innerHTML = series.map(item => `<span class="legend-item"><span class="swatch" style="background:${item.color}"></span>${escapeHtml(item.name)}</span>`).join("");
      if (!series.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, "No link-quality history collected yet.");
        hideChartTooltip();
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
        const dots = item.samples.map(sample => svg("circle", {
          class: "chart-point",
          cx: x(sample).toFixed(1),
          cy: y(sample).toFixed(1),
          r: 4,
          fill: item.color,
          "data-tooltip": tooltipText([
            item.name,
            dateTimeLabel(sample.timestamp),
            `Average latency: ${ms(sample.avgMs)}`,
            `Max latency: ${ms(sample.maxMs)}`,
            `Jitter: ${ms(sample.jitterMs)}`,
            `Packet loss: ${percent(sample.packetLossPercent)}`,
          ]),
        })).join("");
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
      attachChartTooltips(chart);
    };
    const renderCmapSeriesChart = (chart, legend, series, valueKey, options) => {
      const activeSeries = series.map((item, index) => ({
        ...item,
        color: seriesColors[index % seriesColors.length],
        samples: (item.samples || []).filter(sample => Number.isFinite(sample[valueKey])),
      })).filter(item => item.samples.length);
      legend.innerHTML = activeSeries.map(item => `<span class="legend-item"><span class="swatch" style="background:${item.color}"></span>${escapeHtml(item.name)}</span>`).join("");
      if (!activeSeries.length) {
        chart.innerHTML = svg("text", { x: 32, y: 112 }, options.emptyText);
        hideChartTooltip();
        return { seriesCount: 0, sampleCount: 0 };
      }
      const allSamples = activeSeries.flatMap(item => item.samples);
      const width = 900, height = 220, left = 58, right = 20, top = 20, bottom = 38;
      const minTime = Math.min(...allSamples.map(sample => sample.timestamp));
      const maxTime = Math.max(...allSamples.map(sample => sample.timestamp));
      const values = allSamples.map(sample => sample[valueKey]);
      const minValue = Math.min(...values);
      const maxValue = Math.max(...values);
      const flat = minValue === maxValue;
      const padding = flat ? Math.max(1, maxValue * 0.25) : Math.max(1, (maxValue - minValue) * 0.12);
      const chartMin = Math.max(0, minValue - padding);
      const chartMax = maxValue + padding;
      const span = Math.max(1, chartMax - chartMin);
      const x = sample => left + ((sample.timestamp - minTime) / Math.max(1, maxTime - minTime)) * (width - left - right);
      const y = sample => top + (1 - ((sample[valueKey] - chartMin) / span)) * (height - top - bottom);
      const midValue = chartMin + span / 2;
      const paths = activeSeries.map(item => {
        const points = item.samples.map(sample => `${x(sample).toFixed(1)},${y(sample).toFixed(1)}`).join(" ");
        const dots = item.samples.map(sample => svg("circle", {
          class: "chart-point",
          cx: x(sample).toFixed(1),
          cy: y(sample).toFixed(1),
          r: 4,
          fill: options.pointColor ? options.pointColor(sample) : item.color,
          "data-tooltip": tooltipText([
            item.name,
            dateTimeLabel(sample.timestamp),
            `${options.label}: ${options.format(sample[valueKey])}`,
            ...(options.tooltip ? options.tooltip(item, sample) : []),
            Number.isFinite(sample.latencyAvg) ? `Latency avg: ${number(sample.latencyAvg)}` : null,
            Number.isFinite(sample.latencyMax) ? `Latency max: ${number(sample.latencyMax)}` : null,
            Number.isFinite(sample.jitter) ? `Jitter: ${number(sample.jitter)}` : null,
            Number.isFinite(sample.txPacketDelta) ? `TX packets: ${number(sample.txPacketDelta)}` : null,
            Number.isFinite(sample.rxPacketDelta) ? `RX packets: ${number(sample.rxPacketDelta)}` : null,
            Number.isFinite(sample.errorDelta) ? `Errors: ${number(sample.errorDelta)}` : null,
          ]),
        })).join("");
        return `<polyline fill="none" stroke="${item.color}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" points="${points}"></polyline>${dots}`;
      }).join("");
      chart.innerHTML = [
        svg("line", { class: "grid-line", x1: left, y1: top, x2: left, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: height - bottom, x2: width - right, y2: height - bottom }),
        svg("line", { class: "grid-line", x1: left, y1: top, x2: width - right, y2: top }),
        svg("text", { x: 10, y: top + 4 }, options.format(chartMax)),
        svg("text", { x: 10, y: top + (height - top - bottom) / 2 + 4 }, options.format(midValue)),
        svg("text", { x: 10, y: height - bottom + 4 }, options.format(chartMin)),
        svg("text", { x: 12, y: height / 2, transform: `rotate(-90 12 ${height / 2})`, "text-anchor": "middle" }, options.axisLabel),
        svg("text", { x: left, y: height - 12 }, timeLabel(minTime)),
        svg("text", { x: width / 2 - 34, y: height - 12 }, timeLabel(minTime + (maxTime - minTime) / 2)),
        svg("text", { x: width - right - 72, y: height - 12 }, timeLabel(maxTime)),
        paths,
      ].join("");
      attachChartTooltips(chart);
      return { seriesCount: activeSeries.length, sampleCount: allSamples.length };
    };
    const renderCmapKnetHistory = data => {
      const series = data.series || [];
      const latency = renderCmapSeriesChart(
        document.getElementById("cmapLatencyChart"),
        document.getElementById("cmapLatencyLegend"),
        series,
        "latencyAvg",
        { label: "Average latency (µs)", axisLabel: "µs", format: value => `${number(value)} µs`, emptyText: "No cmap Knet latency history collected yet." }
      );
      const jitterSamples = series.flatMap(item => (item.samples || []).filter(sample => Number.isFinite(sample.jitter)));
      const maxJitter = jitterSamples.length ? Math.max(...jitterSamples.map(sample => sample.jitter)) : null;
      detailChips("cmapLatencyDetail", [
        { value: number(latency.seriesCount), label: "links" },
        { value: number(latency.sampleCount), label: "latency samples" },
        { value: Number.isFinite(maxJitter) ? number(maxJitter) : "unknown", label: "max jitter", status: Number.isFinite(maxJitter) && maxJitter > 0 ? "warn" : "good" },
      ]);

      const packetSeries = series.map(item => ({
        ...item,
        samples: (item.samples || []).map(sample => ({
          ...sample,
          packets: (sample.txPacketDelta || 0) + (sample.rxPacketDelta || 0) + (sample.errorDelta || 0),
        })),
      }));
      const packets = renderCmapSeriesChart(
        document.getElementById("cmapPacketChart"),
        document.getElementById("cmapPacketLegend"),
        packetSeries,
        "packets",
        { label: "Packets/errors per interval", axisLabel: "count", format: number, emptyText: "No cmap Knet packet history collected yet." }
      );
      const errorSamples = series.flatMap(item => (item.samples || []).filter(sample => Number.isFinite(sample.errorDelta) && sample.errorDelta > 0));
      detailChips("cmapPacketDetail", [
        { value: number(packets.seriesCount), label: "links" },
        { value: number(packets.sampleCount), label: "packet samples" },
        { value: number(errorSamples.reduce((sum, sample) => sum + sample.errorDelta, 0)), label: "new errors", status: errorSamples.length ? "bad" : "good" },
      ]);
    };
    const renderTestHistory = data => {
      const series = (data.series || []).map(item => ({ ...item, color: item.kind === "tailmox_tcp" ? "#f59e0b" : seriesColors[0] }));
      const result = renderCmapSeriesChart(document.getElementById("testHistoryChart"), document.getElementById("testHistoryLegend"), series, "avgMs", { label: "Average latency", axisLabel: "ms", format: ms, emptyText: "No exported tailmox test samples yet." });
      detailChips("testHistoryDetail", [{ value: number(result.seriesCount), label: "targets" }, { value: number(result.sampleCount), label: "samples" }, { value: "1h", label: "window" }]);
    };
    try {
      const previousStatus = JSON.parse(localStorage.getItem("tailmox-overall-status") || "null");
      const overall = document.getElementById("overall");
      if (previousStatus?.className && previousStatus?.label) {
        overall.className = previousStatus.className;
        overall.lastElementChild.textContent = previousStatus.label;
      }
    } catch { /* Ignore unavailable or malformed browser storage. */ }
    let latestStatus = null;
    async function refreshStatus() {
      const response = await fetch(`${apiPrefix}/api/status`, { cache: "no-store" });
      const data = await response.json();
      latestStatus = data;
      document.getElementById("subtitle").textContent = `${data.hostname} refreshed ${new Date(data.generatedAt * 1000).toLocaleString()}`;
      const overall = document.getElementById("overall");
      const statusLabel = data.overall === "healthy" ? "Healthy" : "Needs attention";
      overall.className = `pill ${data.overall === "healthy" ? "ok" : "warn"}`;
      overall.lastElementChild.textContent = statusLabel;
      localStorage.setItem("tailmox-overall-status", JSON.stringify({ className: overall.className, label: statusLabel }));
      text("tailmoxState", data.tailmox.active ? "active" : (data.tailmox.status || "unknown"));
      text("tailmoxDetail", `${number(data.tailmox.activeMemberCount)} active in state; ${number(data.tailmox.configuredNodeCount)} configured. ${data.tailmox.detail || ""}`);
      text("corosyncState", yesNo(data.services.corosync.active));
      text("corosyncEnabled", `enabled: ${data.services.corosync.enabled || "unknown"}`);
      text("quorumState", data.cluster.quorate === "Yes" ? "quorate" : "not quorate");
      text("votes", `${data.cluster.totalVotes || "?"} of ${data.cluster.expectedVotes || "?"} expected votes`);
      text("clusterName", data.cluster.name || "none");
      text("transport", `transport: ${data.cluster.transport || "unknown"}`);
      text("tailscaleState", data.tailscale.backendState || "unknown");
      text("tailscaleName", data.tailscale.self.DNSName || data.tailscale.self.HostName || "");
      text("influxState", data.influxdb.enabled ? (data.influxdb.online ? "online" : "offline") : "off");
      text("influxDetail", data.influxdb.enabled ? (data.influxdb.detail || "health unknown") : "not configured");
      const offlineCount = (data.corosync.offlineMembers || []).length;
      setPanelStatus("tailmoxPanel", data.tailmox.status === "active" ? "good" : (data.tailmox.active ? "warn" : "bad"));
      setPanelStatus("corosyncPanel", data.services.corosync.active ? (offlineCount ? "warn" : "good") : "bad");
      setPanelStatus("quorumPanel", data.cluster.quorate === "Yes" ? (offlineCount ? "warn" : "good") : "bad");
      setPanelStatus("clusterPanel", data.cluster.name ? (offlineCount ? "warn" : "good") : "bad");
      setPanelStatus("tailscalePanel", data.tailscale.backendState === "Running" ? "good" : "bad");
      setPanelStatus("influxPanel", data.influxdb.enabled ? (data.influxdb.online ? "good" : "bad") : "warn");
      document.getElementById("members").innerHTML = (data.corosync.members || []).map(member => `<tr><td>${escapeHtml(member.name || "")}${member.local ? " (local)" : ""}</td><td>${escapeHtml(member.ip || "")}</td><td>${escapeHtml(member.nodeid || "")}</td><td>${number(member.votes)}</td><td><span class="tag ${member.active ? "joined" : "offline"}">${member.active ? "active" : "offline"}</span></td></tr>`).join("") || "<tr><td colspan='5'>No member data available</td></tr>";
      document.getElementById("quorumNodes").innerHTML = (data.corosync.quorumNodes || []).map(node => `<tr><td>${escapeHtml(node.name || "")}</td><td>${escapeHtml(node.nodeid || "")}</td><td>${escapeHtml(node.votes || "")}</td><td>${node.local ? "yes" : ""}</td></tr>`).join("") || "<tr><td colspan='4'>No quorum node data available</td></tr>";
      renderLogs(data.corosync.recentLogs);
      text("raw", data.corosync.rawStatus || "No pvecm status output available.");
    }
    async function refreshLinkQuality() {
      document.getElementById("linkQuality").innerHTML = "<tr><td colspan='9'><span class='loading'><span class='spinner'></span>Measuring corosync link quality...</span></td></tr>";
      const response = await fetch(`${apiPrefix}/api/link-quality`, { cache: "no-store" });
      const data = await response.json();
      renderLinkQuality(data.links);
      await refreshLinkQualityHistory();
    }
    async function refreshLinkQualityHistory() {
      const response = await fetch(`${apiPrefix}/api/link-quality-history`, { cache: "no-store" });
      const data = await response.json();
      renderLinkQualityHistory(data);
    }
    async function refreshMtuHistory() {
      const response = await fetch(`${apiPrefix}/api/mtu-history`, { cache: "no-store" });
      const data = await response.json();
      renderMtu(data);
    }
    async function refreshMemberCountHistory() {
      const response = await fetch(`${apiPrefix}/api/member-count-history`, { cache: "no-store" });
      const data = await response.json();
      const liveSample = latestStatus?.corosync?.memberCount;
      if (liveSample && Number.isFinite(liveSample.memberCount)) {
        const history = [...(data.history || [])];
        const last = history[history.length - 1];
        if (!last || liveSample.timestamp > last.timestamp) history.push(liveSample);
        data.current = { ...(data.current || {}), ...liveSample };
        data.history = history;
      }
      renderMemberCount(data);
    }
    async function refreshCmapKnetHistory() {
      const response = await fetch(`${apiPrefix}/api/cmap-knet-history`, { cache: "no-store" });
      const data = await response.json();
      renderCmapKnetHistory(data);
    }
    async function refreshTestHistory() {
      const response = await fetch(`${apiPrefix}/api/test-history`, { cache: "no-store" });
      renderTestHistory(await response.json());
    }
    async function refresh() {
      await refreshStatus();
      await Promise.allSettled([
        refreshMtuHistory(),
        refreshMemberCountHistory(),
        refreshCmapKnetHistory(),
        refreshTestHistory(),
        refreshLinkQuality(),
      ]);
    }
    refresh();
    setInterval(refreshStatus, 15000);
    setInterval(refreshMtuHistory, 15000);
    setInterval(refreshMemberCountHistory, 15000);
    setInterval(refreshCmapKnetHistory, 15000);
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
  <title>Tailmox Identity &amp; InfluxDB Settings</title>
  <style>
__MONITOR_FORM_STYLE__
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Tailmox Identity &amp; InfluxDB Settings</h1>
        <div class="muted">Load the cluster age identity, approve host configuration, and configure monitor exports.</div>
      </div>
      <div class="actions">
        <label class="page-picker">Page
          <select id="pagePicker" aria-label="Tailmox page">
          <option value="id">ID</option>
          <option value="settings">Settings</option>
          <option value="health">Health</option>
          <option value="./">Monitor</option>
          <option value="disable">Disable Tailmox</option>
          </select>
        </label>
        <div class="pill" id="overall"><span class="dot"></span><span>Loading</span></div>
      </div>
    </header>
    <section class="panel security-grid">
      <h2>Encryption &amp; host signing</h2>
      <div class="muted" id="securityStatus">Checking this host...</div>
      <div class="identity-details" id="identityDetails" hidden>
        <div class="identity-detail"><span>Identity</span><span id="identityType"></span></div>
        <div class="identity-detail"><span>Loaded on</span><span id="identityHost"></span></div>
        <div class="identity-detail"><span>Cluster match</span><span id="identityMatch"></span></div>
        <div class="identity-detail"><span>Host signer</span><span id="identitySigner"></span></div>
        <div class="identity-detail"><span>Fingerprint</span><span class="recipient" id="identityFingerprint"></span></div>
        <div class="identity-detail"><span>Public signing key</span><span class="public-key" id="identitySigningPublicKey"></span></div>
        <div class="identity-detail"><span>Public recipient</span><span class="recipient" id="identityRecipient"></span></div>
      </div>
      <div id="identitySetup">
        <textarea id="ageIdentity" autocomplete="off" spellcheck="false" placeholder="AGE-SECRET-KEY-PQ-1..."></textarea>
        <div class="actions">
          <button type="button" id="createIdentity">Create Tailmox age identity</button>
          <button type="button" id="addIdentity">Add existing identity</button>
        </div>
      </div>
      <div id="identityBackup" hidden>
        <label>Back up this private identity now<textarea id="generatedIdentity" readonly></textarea></label>
        <div class="muted">It will not be displayed again after this page is closed or refreshed.</div>
      </div>
      <div class="message" id="securityMessage"></div>
      <div id="proposals"></div>
    </section>
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
    const apiPrefix = (window.location.pathname === "/monitor" || window.location.pathname.startsWith("/monitor/")) ? "/monitor" : (window.location.pathname === "/control" || window.location.pathname.startsWith("/control/") ? "/control" : "");
    const pagePicker = document.getElementById("pagePicker");
    const overall = document.getElementById("overall");
    try {
      const previousStatus = JSON.parse(localStorage.getItem("tailmox-overall-status") || "null");
      if (previousStatus?.className && previousStatus?.label) {
        overall.className = previousStatus.className;
        overall.lastElementChild.textContent = previousStatus.label;
      }
    } catch { /* Ignore unavailable or malformed browser storage. */ }
    const currentPage = window.location.pathname.endsWith("/id") ? "id" : window.location.pathname.endsWith("/settings") ? "settings" : "./";
    pagePicker.value = currentPage;
    pagePicker.addEventListener("change", event => {
      const target = event.target.value.replace("./", "");
      window.location.href = apiPrefix ? `${apiPrefix}/${target}` : event.target.value;
    });
    fetch(`${apiPrefix}/api/status`, { cache: "no-store" }).then(response => response.json()).then(data => {
      const statusLabel = data.overall === "healthy" ? "Healthy" : "Needs attention";
      overall.className = `pill ${data.overall === "healthy" ? "ok" : "warn"}`;
      overall.lastElementChild.textContent = statusLabel;
      localStorage.setItem("tailmox-overall-status", JSON.stringify({ className: overall.className, label: statusLabel }));
    }).catch(() => {
      // Preserve the last confirmed status while the page/API is unavailable.
    });
    const message = document.getElementById("message");
    const securityMessage = document.getElementById("securityMessage");
    const identityInput = document.getElementById("ageIdentity");
    async function api(path, options = {}) {
      const response = await fetch(`${apiPrefix}${path}`, {
        cache: "no-store",
        ...options,
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken, ...(options.headers || {}) },
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "Tailmox request failed.");
      return data;
    }
    async function loadSecurity() {
      try {
        const data = await api("/api/security");
        const identity = data.identity;
        const monitorOption = document.querySelector('#pagePicker option[value="./"]');
        if (identity.configured && !monitorOption) {
          document.getElementById("pagePicker").add(new Option("Monitor", "./"));
        }
        document.getElementById("securityStatus").textContent = identity.configured
          ? `Tailmox age identity loaded${data.legacyConfiguration ? " · plaintext configuration migration pending" : ""}`
          : `Create the cluster identity on the first host, or add the existing cluster identity here.${data.legacyConfiguration ? " Existing plaintext settings will remain active until the encrypted migration is approved." : ""}`;
        const details = document.getElementById("identityDetails");
        details.hidden = !identity.configured;
        document.getElementById("identitySetup").hidden = Boolean(identity.configured);
        if (identity.configured) {
          document.getElementById("identityType").textContent = identity.postQuantum ? "Post-quantum ML-KEM-768 + X25519" : "Classic age identity";
          document.getElementById("identityHost").textContent = identity.host;
          document.getElementById("identityMatch").textContent = identity.matchesCluster ? "Verified" : "Not registered or does not match";
          document.getElementById("identitySigner").textContent = identity.signingKeyConfigured ? "Dedicated Ed25519 key loaded" : "Not created yet";
          document.getElementById("identityFingerprint").textContent = identity.recipientFingerprint || "Unavailable";
          document.getElementById("identitySigningPublicKey").textContent = identity.signingPublicKey || "Unavailable";
          const recipient = identity.recipient || "";
          document.getElementById("identityRecipient").textContent = recipient.length > 32
            ? `${recipient.slice(0, 18)}…${recipient.slice(-10)}`
            : (recipient || "Not registered yet");
        }
        document.getElementById("createIdentity").disabled = Boolean(identity.recipient);
        const proposals = document.getElementById("proposals");
        proposals.replaceChildren(...data.proposals.filter(item => !item.activated).map(item => {
          const card = document.createElement("div");
          card.className = "proposal";
          const title = document.createElement("strong");
          title.textContent = item.error ? item.proposalId : `Revision ${item.revision} · ${item.summary}`;
          const detail = document.createElement("div");
          detail.className = "muted";
          detail.textContent = item.error || `Proposed by ${item.proposer}; ${Object.values(item.receipts).filter(value => value === "accepted").length} of ${Object.keys(item.receipts).length} hosts accepted.`;
          card.append(title, detail);
          if (!item.error && item.receipts[data.identity.host] !== "accepted") {
            const actions = document.createElement("div");
            actions.className = "proposal-actions";
            for (const decision of ["accepted", "rejected"]) {
              const button = document.createElement("button");
              button.type = "button";
              button.textContent = decision === "accepted" ? "Accept" : "Reject";
              button.addEventListener("click", async () => {
                try {
                  await api(`/api/proposals/${item.proposalId}`, { method: "POST", body: JSON.stringify({ decision }) });
                  await loadSecurity();
                  await loadSettings();
                } catch (error) { securityMessage.textContent = error.message; }
              });
              actions.append(button);
            }
            card.append(actions);
          }
          return card;
        }));
      } catch (error) {
        securityMessage.className = "message error";
        securityMessage.textContent = error.message;
      }
    }
    async function configureIdentity(operation) {
      securityMessage.className = "message";
      securityMessage.textContent = operation === "create" ? "Creating keys..." : "Checking identity...";
      try {
        const data = await api("/api/security", {
          method: "POST",
          body: JSON.stringify({ operation, identity: identityInput.value }),
        });
        if (data.identity) {
          document.getElementById("generatedIdentity").value = data.identity;
          document.getElementById("identityBackup").hidden = false;
          identityInput.value = "";
          securityMessage.textContent = "Post-quantum identity created. Back it up now, then add this same identity on every Tailmox host.";
        } else {
          identityInput.value = "";
          securityMessage.textContent = "Identity added to this host.";
        }
        securityMessage.className = "message ok";
        await loadSecurity();
        await loadSettings();
      } catch (error) {
        securityMessage.className = "message error";
        securityMessage.textContent = error.message;
      }
    }
    document.getElementById("createIdentity").addEventListener("click", () => configureIdentity("create"));
    document.getElementById("addIdentity").addEventListener("click", () => configureIdentity("import"));
    async function loadSettings() {
      if (!document.getElementById("influxForm")) return;
      const response = await fetch(`${apiPrefix}/api/influxdb`, { cache: "no-store" });
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
      const response = await fetch(`${apiPrefix}/api/influxdb`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
        body: JSON.stringify(body),
      });
      const data = await response.json();
      if (response.ok) {
        document.getElementById("token").value = "";
        document.getElementById("token").placeholder = data.tokenConfigured ? "Current token is saved; leave blank to keep it" : "Paste an InfluxDB token";
        message.className = "message ok";
        message.textContent = data.proposal?.activated
          ? "Saved and activated after host approval."
          : "Proposal saved. Every registered host must accept it before activation.";
        await loadSecurity();
      } else {
        message.className = "message error";
        message.textContent = data.error || "Unable to save settings.";
      }
    });
    loadSecurity();
    loadSettings();
  </script>
</body>
</html>
"""


MONITOR_FORM_STYLE = (MONITOR_DIR / "web" / "monitor-forms.css").read_text()
EDIT_INFLUX_HTML = EDIT_INFLUX_HTML.replace("__MONITOR_FORM_STYLE__", MONITOR_FORM_STYLE)

ID_HTML = re.sub(
    r'    <section class="panel">\n      <h2>Export Destination</h2>.*?    </section>\n',
    "",
    EDIT_INFLUX_HTML,
    count=1,
    flags=re.DOTALL,
).replace("    loadSecurity();\n    loadSettings();", "    loadSecurity();")
ID_HTML = ID_HTML.replace('          <option value="./">Monitor</option>\n', "")
ID_HTML = re.sub(
    r'    document\.getElementById\("influxForm"\)\.addEventListener\(.*?(?=    loadSecurity\(\);)',
    "",
    ID_HTML,
    count=1,
    flags=re.DOTALL,
)
SETTINGS_HTML = EDIT_INFLUX_HTML


class Handler(BaseHTTPRequestHandler):
    def send_body(self, status, content_type, body, extra_headers=None):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'; base-uri 'none'; object-src 'none'")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            return

    def send_json(self, status, payload):
        self.send_body(status, "application/json", json.dumps(payload))

    def require_tailscale_user(self):
        # Cloudflare always adds these headers. Refuse privileged authentication
        # if this service is ever routed through a Cloudflare proxy by mistake.
        if any(
            self.headers.get(name)
            for name in ("CF-Ray", "CF-Connecting-IP", "CF-IPCountry", "CDN-Loop")
        ):
            self.send_json(403, {"error": "Privileged Tailmox pages are private to Tailscale Serve."})
            return None
        login = request_identity(self.headers)
        if login:
            return login
        self.send_json(403, {"error": "Tailmox settings require Tailscale Serve user identity."})
        return None

    def read_json_request(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("Invalid request length.") from error
        if length < 0 or length > 1024 * 1024:
            raise ValueError("The request is too large.")
        value = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        if not isinstance(value, dict):
            raise ValueError("Expected a JSON object.")
        return value

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/monitor" or path.startswith("/monitor/"):
            path = path.removeprefix("/monitor") or "/"
        if path == "/health":
            self.send_body(200, "text/html; charset=utf-8", HEALTH_HTML)
        elif path in ("/", "/index.html"):
            if not self.require_tailscale_user():
                return
            try:
                identity_loaded = bool(tailmox_config.identity_status().get("configured"))
            except tailmox_config.ConfigError:
                identity_loaded = False
            if not identity_loaded:
                self.send_body(
                    200,
                    "text/html; charset=utf-8",
                    ID_HTML.replace("__CSRF_TOKEN__", CSRF_TOKEN),
                    {"Set-Cookie": "tailmox_csrf=1; Path=/; SameSite=Strict; Secure"},
                )
                return
            self.send_body(
                200,
                "text/html; charset=utf-8",
                INDEX_HTML.replace("__CSRF_TOKEN__", CSRF_TOKEN),
                {"Set-Cookie": "tailmox_csrf=1; Path=/; SameSite=Strict; Secure"},
            )
        elif path in ("/id", "/editInfluxDB"):
            if not self.require_tailscale_user():
                return
            self.send_body(
                200,
                "text/html; charset=utf-8",
                ID_HTML.replace("__CSRF_TOKEN__", CSRF_TOKEN),
                {"Set-Cookie": "tailmox_csrf=1; Path=/; SameSite=Strict; Secure"},
            )
        elif path == "/disable":
            if not self.require_tailscale_user():
                return
            self.send_body(200, "text/html; charset=utf-8",
                           (MONITOR_DIR / "web" / "disable.html").read_text()
                           .replace("__MONITOR_FORM_STYLE__", MONITOR_FORM_STYLE)
                           .replace("__CSRF_TOKEN__", CSRF_TOKEN))
        elif path == "/api/migration/subnets":
            if not self.require_tailscale_user():
                return
            try:
                self.send_json(200, {"subnets": discover_subnets()})
            except RuntimeError as error:
                self.send_json(503, {"error": str(error)})
        elif path == "/api/migration":
            owner = self.require_tailscale_user()
            if not owner:
                return
            try:
                self.send_json(200, MIGRATION_CONTROL.snapshot(owner))
            except RuntimeError as error:
                self.send_json(409, {"error": str(error)})
        elif path == "/settings":
            if not self.require_tailscale_user():
                return
            try:
                identity_loaded = bool(tailmox_config.identity_status().get("configured"))
            except tailmox_config.ConfigError:
                identity_loaded = False
            if not identity_loaded:
                self.send_response(302)
                self.send_header("Location", "/id")
                self.end_headers()
                return
            self.send_body(
                200,
                "text/html; charset=utf-8",
                SETTINGS_HTML.replace("__CSRF_TOKEN__", CSRF_TOKEN),
                {"Set-Cookie": "tailmox_csrf=1; Path=/; SameSite=Strict; Secure"},
            )
        elif path == "/api/status":
            self.send_json(200, collect_status())
        elif path == "/api/link-quality":
            self.send_json(200, collect_link_quality())
        elif path == "/api/link-quality-history":
            self.send_json(200, collect_link_quality_history())
        elif path == "/api/mtu-history":
            self.send_json(200, collect_mtu_history())
        elif path == "/api/member-count-history":
            self.send_json(200, collect_member_count_history())
        elif path == "/api/cmap-knet-history":
            self.send_json(200, collect_cmap_knet_history())
        elif path == "/api/test-history":
            self.send_json(200, collect_test_history())
        elif path == "/api/influxdb":
            if not self.require_tailscale_user():
                return
            self.send_json(200, influx_settings_payload())
        elif path == "/api/security":
            if not self.require_tailscale_user():
                return
            try:
                self.send_json(
                    200,
                    {
                        "identity": tailmox_config.identity_status(),
                        "proposals": tailmox_config.list_proposals(),
                        "legacyConfiguration": os.path.isfile(LEGACY_CONFIG_FILE)
                        or os.path.isfile(INFLUX_ENV_FILE),
                        "configReadable": encrypted_config_readable(),
                        "csrfToken": CSRF_TOKEN,
                    },
                )
            except tailmox_config.ConfigError as error:
                self.send_json(409, {"error": str(error)})
        elif path == "/api/actions":
            if not self.require_tailscale_user():
                return
            self.send_json(200, action_snapshot())
        else:
            self.send_body(404, "text/plain; charset=utf-8", "not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if path not in ("/api/migration/start", "/api/migration/decide", "/api/influxdb", "/api/security") and not path.startswith("/api/proposals/") and not path.startswith("/api/actions/"):
            self.send_body(404, "text/plain; charset=utf-8", "not found")
            return
        owner = self.require_tailscale_user()
        if not owner:
            return
        if self.headers.get("X-CSRF-Token") != CSRF_TOKEN:
            self.send_json(403, {"error": "Invalid CSRF token."})
            return

        try:
            payload = self.read_json_request()
            if path == "/api/migration/start":
                with ACTION_LOCK:
                    if ACTION_STATE["status"] == "running":
                        raise RuntimeError("Another Tailmox workflow is already running.")
                    result = MIGRATION_CONTROL.start(owner, payload)
                self.send_json(202, result)
                return
            if path == "/api/migration/decide":
                self.send_json(202, MIGRATION_CONTROL.decide(owner, payload))
                return
            if path.startswith("/api/actions/"):
                self.send_json(202, start_action(path.removeprefix("/api/actions/"), payload))
                return
            if path == "/api/influxdb":
                self.send_json(200, save_influx_config(payload))
                return
            if path == "/api/security":
                operation = payload.get("operation")
                if operation == "create":
                    result = tailmox_config.create_identity()
                elif operation == "import":
                    result = tailmox_config.install_identity(str(payload.get("identity", "")))
                else:
                    raise ValueError("Unknown identity operation.")
                self.send_json(200, initialize_encrypted_configuration(result))
                return
            proposal_id = path.removeprefix("/api/proposals/")
            result = tailmox_config.decide_proposal(
                proposal_id, str(payload.get("decision", ""))
            )
            if result.get("activated"):
                remove_legacy_config()
            self.send_json(200, result)
        except (ValueError, json.JSONDecodeError, UnicodeError) as error:
            self.send_json(400, {"error": str(error)})
        except RuntimeError as error:
            self.send_json(409, {"error": str(error)})
        except tailmox_config.ConfigError as error:
            self.send_json(409, {"error": str(error)})
        except OSError as error:
            self.send_json(500, {"error": str(error)})

    def log_message(self, fmt, *args):
        return


class MonitorHTTPServer(ThreadingHTTPServer):
    """Bound concurrent requests so persistent SSE clients cannot exhaust threads."""

    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, *args, **kwargs):
        self._request_slots = threading.BoundedSemaphore(MAX_HTTP_THREADS)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


if __name__ == "__main__":
    start_cmap_stats_exporter()
    start_public_snapshot_exporter()
    server = MonitorHTTPServer((HOST, PORT), Handler)
    print(f"Tailmox monitor listening on http://{HOST}:{PORT}")
    server.serve_forever()
