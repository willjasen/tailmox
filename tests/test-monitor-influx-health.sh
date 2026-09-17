#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$ROOT_DIR" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import os
import runpy
import urllib.error
from unittest.mock import patch

module = runpy.run_path(os.path.join(os.environ["ROOT_DIR"], "tailmox-monitor.py"))
configured = {"url": "https://influx.example", "token": "secret", "org": "tailmox", "bucket": "metrics"}

class Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

with patch.dict(module["collect_influx_health"].__globals__, {"influx_config": lambda: configured}):
    with patch.object(module["urllib"].request, "urlopen", return_value=Response()) as urlopen:
        health = module["collect_influx_health"]()
        assert health["online"] is True
        assert health["detail"] == "HTTP 200"
        request = urlopen.call_args.args[0]
        assert request.full_url == "https://influx.example/health"
        assert request.get_method() == "GET"
        assert urlopen.call_args.kwargs["timeout"] == module["INFLUX_HEALTH_TIMEOUT_SECONDS"]

    with patch.object(module["urllib"].request, "urlopen", side_effect=urllib.error.URLError("refused")):
        health = module["collect_influx_health"]()
        assert health["online"] is False
        assert "refused" in health["detail"]

with patch.dict(module["collect_influx_health"].__globals__, {"influx_config": lambda: {"url": "", "token": "", "org": "", "bucket": ""}}):
    with patch.object(module["urllib"].request, "urlopen") as urlopen:
        health = module["collect_influx_health"]()
        assert health["enabled"] is False
        assert health["online"] is None
        assert health["detail"] == "not configured"
        urlopen.assert_not_called()

assert 'add("InfluxDB is offline"' in module["HEALTH_HTML"]
assert 'data.influxdb.online ? "online" : "offline"' in module["INDEX_HTML"]
PY

printf 'PASS: monitor probes configured InfluxDB health\n'
