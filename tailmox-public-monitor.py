#!/usr/bin/env python3
"""Unprivileged, public-only Tailmox status server."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import pathlib
import re
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


def index_page():
    body = (WEB_ROOT / "index.html").read_text(encoding="utf-8")
    snippet = ""
    if GA_MEASUREMENT_ID:
        snippet = (
            f'<script async src="https://www.googletagmanager.com/gtag/js?id={GA_MEASUREMENT_ID}"></script>\n'
            '  <script src="/google-analytics.js" defer></script>'
        )
    return body.replace("<!-- __GOOGLE_ANALYTICS__ -->", snippet).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "Tailmox"
    sys_version = ""

    def host_allowed(self):
        host = self.headers.get("Host", "").rsplit(":", 1)[0].rstrip(".").lower()
        return host in ALLOWED_HOSTS

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
            raw = SNAPSHOT_FILE.read_bytes()
            if len(raw) > MAX_SNAPSHOT_BYTES:
                raise ValueError("snapshot too large")
            snapshot = json.loads(raw)
            generated = int(snapshot.get("generatedAt", 0))
            import time

            if generated <= 0 or time.time() - generated > MAX_SNAPSHOT_AGE_SECONDS:
                self.send_text(503, "status temporarily unavailable\n")
                return
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
            body = index_page() if name == "index.html" else (WEB_ROOT / name).read_bytes()
        except OSError:
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


if __name__ == "__main__":
    server = Server((HOST, PORT), Handler)
    print(f"Tailmox public monitor listening on http://{HOST}:{PORT}")
    server.serve_forever()
