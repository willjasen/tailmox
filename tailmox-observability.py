#!/usr/bin/env python3
"""Read-only cluster audit for Tailmox monitors and InfluxDB exports."""

import importlib.util
import os
import pathlib
import re
import socket
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parent
MONITOR_MODULE = pathlib.Path(
    os.environ.get("TAILMOX_OBSERVABILITY_MONITOR_MODULE", ROOT / "tailmox-monitor.py")
)
MAX_AGE_SECONDS = max(
    60, int(os.environ.get("TAILMOX_OBSERVABILITY_MAX_AGE_SECONDS", "180"))
)
HOST_PATTERN = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?")
MEASUREMENTS = {
    "icmp": ("tailmox_icmp", "average_ms"),
    "tcp": ("tailmox_tcp", "latency_ms"),
    "cmap": ("tailmox_corosync_cmap_stat", "value"),
    "link-quality": ("tailmox_corosync_link_quality", "avg_ms"),
}


def command(arguments, timeout=10):
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "stdout": "", "detail": str(error)}
    return {
        "ok": result.returncode == 0,
        "stdout": result.stdout.strip(),
        "detail": result.stderr.strip(),
    }


def discover_hosts():
    override = os.environ.get("TAILMOX_OBSERVABILITY_HOSTS", "")
    if override:
        candidates = [value.strip() for value in override.split(",") if value.strip()]
    else:
        result = command(["pvecm", "nodes"])
        if not result["ok"]:
            raise RuntimeError(result["detail"] or "pvecm nodes failed")
        candidates = []
        for line in result["stdout"].splitlines():
            fields = line.split()
            if len(fields) >= 3 and fields[0].isdigit() and fields[1].isdigit():
                candidates.append(fields[2])
    hosts = sorted(set(candidates))
    if not hosts or any(not HOST_PATTERN.fullmatch(host) for host in hosts):
        raise RuntimeError("cluster host discovery returned incomplete or unsafe names")
    return hosts


def host_command(host, arguments):
    local_host = os.environ.get("TAILMOX_OBSERVABILITY_LOCAL_HOST", socket.gethostname())
    if host == local_host:
        return command(arguments)
    return command(
        [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            f"root@{host}", "--", *arguments,
        ],
        timeout=12,
    )


def check_host(host):
    checks = {}
    for label, service in (
        ("monitor", "tailmox-monitor.service"),
        ("exporter", "tailmox-influx.service"),
    ):
        active = host_command(host, ["systemctl", "is-active", service])
        enabled = host_command(host, ["systemctl", "is-enabled", service])
        checks[f"{label}_active"] = active["ok"] and active["stdout"] == "active"
        checks[f"{label}_enabled"] = enabled["ok"] and enabled["stdout"] == "enabled"
    try:
        with socket.create_connection((host, 8088), timeout=4):
            checks["monitor_port"] = True
    except OSError:
        checks["monitor_port"] = False
    return checks


def load_monitor_module():
    specification = importlib.util.spec_from_file_location(
        "tailmox_observability_monitor", MONITOR_MODULE
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("unable to load the Tailmox monitor module")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def query_latest(module, measurement, field, group_columns):
    config = module.influx_config()
    bucket = module.escape_string(config["bucket"])
    columns = ", ".join(f'"{column}"' for column in group_columns)
    return module.influx_query(f'''
from(bucket: "{bucket}")
  |> range(start: -10m)
  |> filter(fn: (r) => r._measurement == "{measurement}" and r._field == "{field}")
  |> group(columns: [{columns}])
  |> last()
''', timeout=15)


def audit_influx():
    module = load_monitor_module()
    now = time.time()
    measurements = {}
    for label, (measurement, field) in MEASUREMENTS.items():
        rows = query_latest(module, measurement, field, ["host"])
        measurements[label] = {
            row["host"]: max(0, int(now - module.influx_time(row.get("_time"))))
            for row in rows
            if row.get("host") and module.influx_time(row.get("_time")) is not None
        }
    rows = query_latest(
        module, "tailmox_corosync_link_quality", "avg_ms", ["host", "peer_host"]
    )
    link_pairs = {
        (row["host"], row["peer_host"]): max(
            0, int(now - module.influx_time(row.get("_time")))
        )
        for row in rows
        if row.get("host") and row.get("peer_host")
        and module.influx_time(row.get("_time")) is not None
    }
    return {"measurements": measurements, "link_pairs": link_pairs}


def run_audit():
    hosts = discover_hosts()
    expected = set(hosts)
    failed = False
    print(f"Tailmox observability audit: {len(hosts)} hosts")
    for host in hosts:
        checks = check_host(host)
        missing = [name.replace("_", " ") for name, passed in checks.items() if not passed]
        if missing:
            failed = True
            print(f"FAIL {host}: {', '.join(missing)}")
        else:
            print(f"PASS {host}: monitor and exporter active, enabled, and reachable")

    influx = audit_influx()
    for label in MEASUREMENTS:
        ages = influx["measurements"].get(label, {})
        missing = sorted(expected - set(ages))
        stale = sorted(host for host, age in ages.items() if host in expected and age > MAX_AGE_SECONDS)
        unexpected = sorted(set(ages) - expected)
        if missing or stale or unexpected:
            failed = True
            details = []
            if missing:
                details.append(f"missing={','.join(missing)}")
            if stale:
                details.append(f"stale={','.join(stale)}")
            if unexpected:
                details.append(f"unexpected={','.join(unexpected)}")
            print(f"FAIL Influx {label}: {' '.join(details)}")
        else:
            print(f"PASS Influx {label}: fresh data from all {len(hosts)} hosts")

    expected_pairs = {(host, peer) for host in hosts for peer in hosts if peer != host}
    actual_pairs = set(influx["link_pairs"])
    missing_pairs = sorted(expected_pairs - actual_pairs)
    stale_pairs = sorted(
        pair for pair, age in influx["link_pairs"].items()
        if pair in expected_pairs and age > MAX_AGE_SECONDS
    )
    unexpected_pairs = sorted(actual_pairs - expected_pairs)
    if missing_pairs or stale_pairs or unexpected_pairs:
        failed = True
        print(
            "FAIL Influx link mesh: "
            f"missing_pairs={len(missing_pairs)} stale_pairs={len(stale_pairs)} "
            f"unexpected_pairs={len(unexpected_pairs)}"
        )
    else:
        print(f"PASS Influx link mesh: all {len(expected_pairs)} directed pairs present")

    if failed:
        print("RESULT: observability audit failed")
        return 1
    print("RESULT: observability audit passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run_audit())
    except (RuntimeError, ValueError) as error:
        print(f"RESULT: observability audit failed: {error}", file=sys.stderr)
        raise SystemExit(1)
