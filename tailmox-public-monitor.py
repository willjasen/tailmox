#!/usr/bin/env python3
"""Unprivileged, public-only Tailmox status server."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import os
import pathlib
import re
import stat
import threading
import time
from urllib.parse import urlsplit


ROOT = pathlib.Path(__file__).resolve().parent
WEB_ROOT = ROOT / "web" / "public-monitor"
SNAPSHOT_FILE = pathlib.Path(
    os.environ.get(
        "TAILMOX_PUBLIC_SNAPSHOT_FILE", "/run/tailmox-public-monitor/status.json"
    )
)
HOST = os.environ.get("TAILMOX_PUBLIC_HOST", "127.0.0.1")
PORT = int(os.environ.get("TAILMOX_PUBLIC_PORT", "8089"))
ALLOWED_HOSTS = {
    value.strip().lower()
    for value in os.environ.get(
        "TAILMOX_PUBLIC_ALLOWED_HOSTS", "tailmox.com,localhost,127.0.0.1"
    ).split(",")
    if value.strip()
}
MAX_SNAPSHOT_AGE_SECONDS = max(
    30, int(os.environ.get("TAILMOX_PUBLIC_MAX_SNAPSHOT_AGE_SECONDS", "120"))
)
MAX_SNAPSHOT_BYTES = min(
    2 * 1024 * 1024,
    max(64 * 1024, int(os.environ.get("TAILMOX_PUBLIC_MAX_SNAPSHOT_BYTES", str(2 * 1024 * 1024)))),
)
MAX_HTTP_THREADS = min(
    128, max(1, int(os.environ.get("TAILMOX_PUBLIC_MAX_HTTP_THREADS", "32")))
)
REQUEST_TIMEOUT_SECONDS = min(
    60, max(1, int(os.environ.get("TAILMOX_PUBLIC_REQUEST_TIMEOUT_SECONDS", "10")))
)
MAX_STATIC_ASSET_BYTES = 1024 * 1024
GA_MEASUREMENT_ID = os.environ.get("TAILMOX_GA_MEASUREMENT_ID", "").strip()
if GA_MEASUREMENT_ID and not re.fullmatch(r"G-[A-Z0-9]+", GA_MEASUREMENT_ID):
    raise ValueError("TAILMOX_GA_MEASUREMENT_ID must be a GA4 measurement ID such as G-ABC123")

SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; "
        "connect-src 'self'; img-src 'self'; base-uri 'none'; "
        "form-action 'none'; frame-ancestors 'none'; object-src 'none'"
    ),
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=31536000",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
}


def security_headers():
    headers = dict(SECURITY_HEADERS)
    if GA_MEASUREMENT_ID:
        headers["Content-Security-Policy"] = (
            "default-src 'none'; "
            "script-src 'self' https://www.googletagmanager.com; "
            "style-src 'self'; "
            "connect-src 'self' https://www.google-analytics.com "
            "https://region1.google-analytics.com; "
            "img-src 'self' https://www.google-analytics.com; base-uri 'none'; "
            "form-action 'none'; frame-ancestors 'none'; object-src 'none'"
        )
    return headers


def analytics_loader():
    return (
        "window.dataLayer=window.dataLayer||[];"
        "function gtag(){dataLayer.push(arguments);}"
        "gtag('js',new Date());"
        f"gtag('config',{json.dumps(GA_MEASUREMENT_ID)},{{'anonymize_ip':true}});\n"
    ).encode("utf-8")


def read_regular_file(path, maximum_bytes):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum_bytes:
            raise ValueError("invalid file")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            body = handle.read(maximum_bytes + 1)
        if len(body) > maximum_bytes:
            raise ValueError("file too large")
        return body
    finally:
        os.close(descriptor)


def index_page():
    body = read_regular_file(
        WEB_ROOT / "index.html", MAX_STATIC_ASSET_BYTES
    ).decode("utf-8")
    snippet = ""
    if GA_MEASUREMENT_ID:
        snippet = (
            f'<script async src="https://www.googletagmanager.com/gtag/js?id={GA_MEASUREMENT_ID}"></script>\n'
            '  <script src="/google-analytics.js" defer></script>'
        )
    return body.replace("<!-- __GOOGLE_ANALYTICS__ -->", snippet).encode("utf-8")


def normalized_host(value):
    """Return a normalized Host value without a port, or None when malformed."""
    if not isinstance(value, str) or not value or len(value) > 255:
        return None
    value = value.strip().lower()
    if not value or any(character.isspace() for character in value):
        return None
    if value.startswith("["):
        closing = value.find("]")
        if closing < 0:
            return None
        host = value[1:closing]
        suffix = value[closing + 1:]
        if suffix and (not suffix.startswith(":") or not suffix[1:].isdigit()):
            return None
        try:
            return str(ipaddress.ip_address(host))
        except ValueError:
            return None
    if value.count(":") > 1:
        return None
    host, separator, port = value.rpartition(":")
    if separator:
        if not port.isdigit():
            return None
        value = host
    value = value.rstrip(".")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", value):
        return None
    return value


def reject_json_constant(value):
    raise ValueError(f"invalid JSON number: {value}")


def bounded_number(value, *, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if integer and not isinstance(value, int):
        return False
    return math.isfinite(value) and abs(value) <= 1_000_000_000_000


def exact_object(value, keys):
    return isinstance(value, dict) and set(value) == set(keys)


GRAPH_FIELDS = {
    "mtu": ("displayMtu", "configuredMtu", "discoveredGlobalMtu", "automatic", "pmtudIntervalSeconds"),
    "members": ("memberCount", "quorumNodeCount", "configuredNodeCount", "offlineNodeCount", "quorate"),
    "linkQuality": ("avgMs", "maxMs", "jitterMs", "packetLossPercent"),
    "cmapKnet": ("latencyAvg", "latencyMax", "jitter", "txPacketDelta", "rxPacketDelta", "errorDelta"),
    "tests": ("avgMs", "maxMs", "received", "sent"),
}


def valid_public_string(value, maximum=160):
    return (
        isinstance(value, str)
        and 0 < len(value) <= maximum
        and all(character.isprintable() for character in value)
    )


def valid_public_hostname(value):
    if not valid_public_string(value):
        return False
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?", value):
        return False
    try:
        ipaddress.ip_address(value.rstrip("."))
        return False
    except ValueError:
        return True


def valid_series_name(value, prefix):
    if not valid_public_string(value):
        return False
    if re.fullmatch(rf"{re.escape(prefix)} [1-9][0-9]?", value):
        return True
    parts = value.split(" → ")
    if 1 <= len(parts) <= 2 and all(valid_public_hostname(part) for part in parts):
        return True
    if prefix == "Link" and len(parts) == 2:
        peer, separator, link_number = parts[1].rpartition(" link ")
        return (
            bool(separator)
            and valid_public_hostname(parts[0])
            and valid_public_hostname(peer)
            and bool(re.fullmatch(r"[0-9]{1,3}", link_number))
        )
    return False


def validate_graphs(graphs):
    if not exact_object(graphs, GRAPH_FIELDS):
        return False
    prefixes = {"mtu": "Node", "members": "Node", "linkQuality": "Link", "cmapKnet": "Link", "tests": "Test"}
    for graph_name, sample_fields in GRAPH_FIELDS.items():
        graph = graphs[graph_name]
        if not exact_object(graph, ("series",)) or not isinstance(graph["series"], list):
            return False
        if len(graph["series"]) > 64:
            return False
        for series in graph["series"]:
            optional = {"kind"} if graph_name == "tests" else ({"host", "peer"} if graph_name == "linkQuality" else set())
            if not isinstance(series, dict) or not {"name", "samples"}.issubset(series):
                return False
            if set(series) - ({"name", "samples"} | optional):
                return False
            if not valid_series_name(series["name"], prefixes[graph_name]) or not isinstance(series["samples"], list) or len(series["samples"]) > 120:
                return False
            for field in optional:
                if field in series and field != "kind" and not valid_public_hostname(series[field]):
                    return False
            if "kind" in series and series["kind"] not in ("tailmox_icmp", "tailmox_tcp"):
                return False
            for sample in series["samples"]:
                if not isinstance(sample, dict) or "timestamp" not in sample:
                    return False
                if set(sample) - ({"timestamp"} | set(sample_fields)):
                    return False
                if not bounded_number(sample["timestamp"]):
                    return False
                for key, value in sample.items():
                    if key == "timestamp":
                        continue
                    if key in ("automatic", "quorate"):
                        if not isinstance(value, bool):
                            return False
                    elif not bounded_number(value):
                        return False
    return True


def validate_snapshot(snapshot, now=None):
    """Fail closed if the root exporter ever emits fields outside the public schema."""
    top_level = (
        "schemaVersion", "generatedAt", "monitorHostname", "overall", "services",
        "cluster", "links", "linkQualityDetails", "web", "metrics", "history", "graphs",
    )
    if not exact_object(snapshot, top_level) or snapshot["schemaVersion"] != 5:
        return False
    generated = snapshot["generatedAt"]
    current_time = time.time() if now is None else now
    if not bounded_number(generated) or generated <= 0:
        return False
    if generated > current_time + 30 or current_time - generated > MAX_SNAPSHOT_AGE_SECONDS:
        return False
    if snapshot["monitorHostname"] is not None and not valid_public_hostname(snapshot["monitorHostname"]):
        return False
    if snapshot["overall"] not in ("healthy", "attention", "unknown"):
        return False
    for key, fields in (
        ("services", ("corosync", "proxmoxCluster", "tailscale")),
        ("cluster", ("quorate", "activeMembers", "configuredMembers", "offlineMembers")),
        ("links", ("healthy", "degraded", "offline", "unknown")),
        ("web", ("online", "total")),
        ("metrics", ("configured", "online")),
    ):
        if not exact_object(snapshot[key], fields):
            return False
    if any(not isinstance(snapshot["services"][field], bool) for field in snapshot["services"]):
        return False
    if not isinstance(snapshot["cluster"]["quorate"], bool):
        return False
    for container in (snapshot["cluster"], snapshot["links"], snapshot["web"]):
        if any(not bounded_number(value, integer=True) or value < 0 for key, value in container.items() if key != "quorate"):
            return False
    metrics_online = snapshot["metrics"]["online"]
    if not isinstance(snapshot["metrics"]["configured"], bool) or (metrics_online is not None and not isinstance(metrics_online, bool)):
        return False
    if not isinstance(snapshot["history"], list) or len(snapshot["history"]) > 120:
        return False
    history_fields = ("timestamp", "activeMembers", "configuredMembers", "healthyLinks", "degradedLinks", "offlineLinks", "webOnline", "webTotal")
    for sample in snapshot["history"]:
        if not exact_object(sample, history_fields) or any(not bounded_number(value) or value < 0 for value in sample.values()):
            return False
    if not isinstance(snapshot["linkQualityDetails"], list) or len(snapshot["linkQualityDetails"]) > 64:
        return False
    detail_fields = {"hostname", "status", "quality", "packetLossPercent", "avgMs", "maxMs", "jitterMs", "lastUpdatedAt"}
    for detail in snapshot["linkQualityDetails"]:
        if not isinstance(detail, dict) or "hostname" not in detail or set(detail) - detail_fields:
            return False
        if detail["hostname"] != "unknown peer" and not valid_public_hostname(detail["hostname"]):
            return False
        if any(not valid_public_string(detail[field], 32) for field in ("status", "quality") if field in detail):
            return False
        if any(not bounded_number(value) for key, value in detail.items() if key not in ("hostname", "status", "quality")):
            return False
    return validate_graphs(snapshot["graphs"])


def read_snapshot():
    raw = read_regular_file(SNAPSHOT_FILE, MAX_SNAPSHOT_BYTES)
    snapshot = json.loads(raw, parse_constant=reject_json_constant)
    if not validate_snapshot(snapshot):
        raise ValueError("invalid public snapshot")
    return raw


class Handler(BaseHTTPRequestHandler):
    server_version = "Tailmox"
    sys_version = ""

    def host_allowed(self):
        get_all = getattr(self.headers, "get_all", None)
        hosts = get_all("Host", []) if get_all else [self.headers.get("Host", "")]
        return len(hosts) == 1 and normalized_host(hosts[0]) in ALLOWED_HOSTS

    def send_bytes(self, status, content_type, body, cache_control="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        for name, value in security_headers().items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def send_text(self, status, body):
        self.send_bytes(status, "text/plain; charset=utf-8", body.encode("utf-8"))

    def serve_snapshot(self):
        try:
            raw = read_snapshot()
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            self.send_text(503, "status temporarily unavailable\n")
            return
        self.send_bytes(
            200,
            "application/json; charset=utf-8",
            raw,
            "public, max-age=5, s-maxage=10, stale-if-error=30",
        )

    def handle_read(self):
        if not self.host_allowed():
            self.send_text(421, "misdirected request\n")
            return
        path = urlsplit(self.path).path
        assets = {
            "/": ("index.html", "text/html; charset=utf-8", "no-store"),
            "/index.html": ("index.html", "text/html; charset=utf-8", "no-store"),
            "/public-monitor.css": ("public-monitor.css", "text/css; charset=utf-8", "public, max-age=86400"),
            "/public-monitor.js": ("public-monitor.js", "text/javascript; charset=utf-8", "public, max-age=86400"),
        }
        if path == "/snapshot.json":
            self.serve_snapshot()
            return
        if path == "/google-analytics.js" and GA_MEASUREMENT_ID:
            self.send_bytes(
                200,
                "text/javascript; charset=utf-8",
                analytics_loader(),
                "public, max-age=300",
            )
            return
        if path not in assets:
            self.send_text(404, "not found\n")
            return
        name, content_type, caching = assets[path]
        try:
            body = index_page() if name == "index.html" else read_regular_file(
                WEB_ROOT / name, MAX_STATIC_ASSET_BYTES
            )
        except (OSError, UnicodeError, ValueError):
            self.send_text(503, "status page unavailable\n")
            return
        self.send_bytes(200, content_type, body, caching)

    do_GET = handle_read
    do_HEAD = handle_read

    def method_not_allowed(self):
        self.send_bytes(
            405,
            "text/plain; charset=utf-8",
            b"method not allowed\n",
            "no-store",
        )

    do_POST = method_not_allowed
    do_PUT = method_not_allowed
    do_PATCH = method_not_allowed
    do_DELETE = method_not_allowed
    do_OPTIONS = method_not_allowed

    def log_message(self, _format, *_args):
        return


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, *args, **kwargs):
        self._request_slots = threading.BoundedSemaphore(MAX_HTTP_THREADS)
        super().__init__(*args, **kwargs)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(REQUEST_TIMEOUT_SECONDS)
        return request, address

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
    server = Server((HOST, PORT), Handler)
    print(f"Tailmox public monitor listening on http://{HOST}:{PORT}")
    server.serve_forever()
