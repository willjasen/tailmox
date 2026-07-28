#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT

SCRIPT_DIR="$TEST_STATE_DIR/script"
SOURCE_DIR="$TEST_STATE_DIR/source"
OUTPUT_DIR="$TEST_STATE_DIR/output"
mkdir -p "$SCRIPT_DIR" "$SOURCE_DIR" "$OUTPUT_DIR"

cp "$TEST_ROOT/test-env/download-template.sh" "$SCRIPT_DIR/download-template.sh"
printf 'metadata that must not be appended\n' >"$SOURCE_DIR/._tailmox.qcow2"
printf 'expected qcow2 payload\n' >"$SOURCE_DIR/tailmox.qcow2"

tar -cJf "$OUTPUT_DIR/tailmox.qcow2.tar.xz" \
  -C "$SOURCE_DIR" \
  ._tailmox.qcow2 \
  tailmox.qcow2

COMPRESSED_SIZE=$(stat -f%z "$OUTPUT_DIR/tailmox.qcow2.tar.xz" 2>/dev/null ||
  stat -c%s "$OUTPUT_DIR/tailmox.qcow2.tar.xz")
UNCOMPRESSED_SIZE=$(stat -f%z "$SOURCE_DIR/tailmox.qcow2" 2>/dev/null ||
  stat -c%s "$SOURCE_DIR/tailmox.qcow2")
if command -v shasum >/dev/null 2>&1; then
  UNCOMPRESSED_HASH=$(shasum -a 256 "$SOURCE_DIR/tailmox.qcow2" | awk '{print $1}')
else
  UNCOMPRESSED_HASH=$(sha256sum "$SOURCE_DIR/tailmox.qcow2" | awk '{print $1}')
fi

printf '%s\n' \
  '{' \
  '  "template": {' \
  '    "versions": {' \
  '      "compressed": {' \
  '        "xz_compressed": true,' \
  '        "name": "tailmox.qcow2.tar.xz",' \
  "        \"size_in_bytes\": $COMPRESSED_SIZE," \
  '        "ipfs": {"cid_v1": "unused-test-cid"}' \
  '      },' \
  '      "uncompressed": {' \
  '        "xz_compressed": false,' \
  '        "name": "tailmox.qcow2",' \
  "        \"size_in_bytes\": $UNCOMPRESSED_SIZE," \
  "        \"hash\": \"sha256:$UNCOMPRESSED_HASH\"," \
  '        "ipfs": {"cid_v1": "unused-test-cid"}' \
  '      }' \
  '    }' \
  '  }' \
  '}' >"$SCRIPT_DIR/template.json"

"$SCRIPT_DIR/download-template.sh" \
  --version compressed \
  --output "$OUTPUT_DIR/tailmox.qcow2" >/dev/null

cmp "$SOURCE_DIR/tailmox.qcow2" "$OUTPUT_DIR/tailmox.qcow2" ||
  { printf 'FAIL: extracted image contains unexpected archive members\n' >&2; exit 1; }

printf 'PASS: download helper extracts only the expected qcow2 archive member\n'
