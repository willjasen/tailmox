#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MOCK_TAILMOX="$TEST_DIR/tailmox"
cat > "$MOCK_TAILMOX" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "stage" ]]; then
    [[ "${TAILMOX_AUTH_KEY:-}" == "tskey-test-only" ]]
    printf 'stage received an environment credential\n'
else
    printf '%s\n' "$*"
fi
MOCK
chmod +x "$MOCK_TAILMOX"

TAILMOX_COMMAND="$MOCK_TAILMOX" ROOT_DIR="$ROOT_DIR" python3 - <<'PY'
import os
import runpy
import time

module = runpy.run_path(os.path.join(os.environ["ROOT_DIR"], "tailmox-monitor.py"))

for action, expected in (
    ("test", "test"),
    ("backup-create", "backups create"),
    ("analytics-install", "analytics install"),
    ("analytics-restart", "analytics restart"),
    ("analytics-uninstall", "analytics uninstall"),
):
    module["start_action"](action, {})
    for _ in range(100):
        state = module["action_snapshot"]()
        if state["status"] != "running":
            break
        time.sleep(0.01)
    assert state["status"] == "succeeded", state
    assert state["output"] == expected, state

module["start_action"]("stage", {"authKey": "tskey-test-only"})
for _ in range(100):
    state = module["action_snapshot"]()
    if state["status"] != "running":
        break
    time.sleep(0.01)
assert state["status"] == "succeeded", state
assert "tskey-test-only" not in state["output"]

try:
    module["start_action"]("not-a-workflow", {})
except ValueError:
    pass
else:
    raise AssertionError("unknown workflow was accepted")

html = module["INDEX_HTML"]
for element in ("<a ", "<button", "<select", "<input", "<form"):
    assert element not in html, element
for behavior in ("runAction", "refreshAction", "showModal", "window.location.href"):
    assert behavior not in html, behavior
assert html.count('class="chart-loading-indicator"') == 6
assert "Loading cmap Knet packet history..." not in html
assert "Loading exported test history..." not in html
assert html.count("last hour") >= 6
assert '{ value: "1h", label: "window" }' in html
PY

printf 'monitor action tests passed\n'
