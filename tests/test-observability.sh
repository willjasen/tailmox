#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

ROOT_DIR="$ROOT_DIR" python3 - <<'PY'
import contextlib
import io
import os
import runpy

module = runpy.run_path(os.path.join(os.environ["ROOT_DIR"], "tailmox-observability.py"))
globals_ = module["run_audit"].__globals__
hosts = ["pve-a1", "pve-a2", "pve3"]
all_checks = {
    "monitor_active": True,
    "monitor_enabled": True,
    "exporter_active": True,
    "exporter_enabled": True,
    "monitor_port": True,
}
all_measurements = {
    label: {host: 30 for host in hosts}
    for label in module["MEASUREMENTS"]
}
all_pairs = {(host, peer): 30 for host in hosts for peer in hosts if host != peer}

globals_["discover_hosts"] = lambda: list(hosts)
globals_["check_host"] = lambda host: dict(all_checks)
globals_["audit_influx"] = lambda: {
    "measurements": all_measurements,
    "link_pairs": all_pairs,
}
output = io.StringIO()
with contextlib.redirect_stdout(output):
    status = module["run_audit"]()
assert status == 0, output.getvalue()
assert "PASS pve-a1: monitor and exporter active, enabled, and reachable" in output.getvalue()
assert "PASS Influx link mesh: all 6 directed pairs present" in output.getvalue()
assert "RESULT: observability audit passed" in output.getvalue()

def failing_host_check(host):
    checks = dict(all_checks)
    if host == "pve-a1":
        checks["monitor_active"] = False
        checks["monitor_port"] = False
    return checks

failed_measurements = {
    label: dict(values) for label, values in all_measurements.items()
}
del failed_measurements["icmp"]["pve3"]
failed_measurements["tcp"]["pve-a2"] = module["MAX_AGE_SECONDS"] + 1
globals_["check_host"] = failing_host_check
globals_["audit_influx"] = lambda: {
    "measurements": failed_measurements,
    "link_pairs": {
        pair: (
            module["MAX_AGE_SECONDS"] + 1
            if pair == ("pve-a2", "pve3") else age
        )
        for pair, age in all_pairs.items() if pair != ("pve3", "pve-a1")
    },
}
output = io.StringIO()
with contextlib.redirect_stdout(output):
    status = module["run_audit"]()
assert status == 1, output.getvalue()
assert "FAIL pve-a1: monitor active, monitor port" in output.getvalue()
assert "FAIL Influx icmp: missing=pve3" in output.getvalue()
assert "FAIL Influx tcp: stale=pve-a2" in output.getvalue()
assert "FAIL Influx link mesh: missing_pairs=1 stale_pairs=1 unexpected_pairs=0" in output.getvalue()
assert "RESULT: observability audit failed" in output.getvalue()

globals_["command"] = lambda arguments, timeout=10: {
    "ok": True,
    "stdout": "Nodeid Votes Name\n1 1 pve-a1\n2 1 pve-a2 (local)\n3 1 pve3",
    "detail": "",
}
os.environ.pop("TAILMOX_OBSERVABILITY_HOSTS", None)
assert module["discover_hosts"]() == hosts

os.environ["TAILMOX_OBSERVABILITY_HOSTS"] = "pve-a1,bad host"
try:
    module["discover_hosts"]()
except RuntimeError:
    pass
else:
    raise AssertionError("unsafe host discovery was accepted")
PY

DISPATCH_DIR="$TEST_DIR/dispatch"
mkdir -p "$DISPATCH_DIR/bin"
cp "$ROOT_DIR/tailmox" "$DISPATCH_DIR/tailmox"
printf '#!/usr/bin/env python3\nprint("observability dispatched")\n' > "$DISPATCH_DIR/tailmox-observability.py"
chmod +x "$DISPATCH_DIR/tailmox" "$DISPATCH_DIR/tailmox-observability.py"
output=$(TAILMOX_BIN_DIR="$DISPATCH_DIR/bin" "$DISPATCH_DIR/tailmox" test observability)
[[ "$output" == "observability dispatched" ]]
if TAILMOX_BIN_DIR="$DISPATCH_DIR/bin" "$DISPATCH_DIR/tailmox" test observability unexpected >/dev/null 2>&1; then
    printf 'FAIL: observability accepted an unexpected argument\n'
    exit 1
fi
if TAILMOX_BIN_DIR="$DISPATCH_DIR/bin" "$DISPATCH_DIR/tailmox" observability >/dev/null 2>&1; then
    printf 'FAIL: legacy top-level observability command is still accepted\n'
    exit 1
fi

printf 'PASS: observability audit covers services, freshness, and complete mesh export\n'
