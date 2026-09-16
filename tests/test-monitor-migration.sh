#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT_DIR" python3 "$ROOT_DIR/tests/monitor-migration.py"
