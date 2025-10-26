#!/usr/bin/env bash
set -euo pipefail

# tailmox-download-template.sh
# Download the template image referenced in tailmox-template.json from IPFS.
# Usage: ./tailmox-download-template.sh [--cid CID] [--gateway URL] [--output FILE]
# If --cid is omitted, the script reads `template.ipfs` from tailmox-template.json located
# next to this script. If `template.name` is present it will be used as the default output filename.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_PATH="$SCRIPT_DIR/template.json"

usage() {
  cat <<EOF
Usage: $0 [--cid CID] [--gateway URL] [--output FILE]

Options:
  --cid CID         IPFS CID to download (defaults to value from $JSON_PATH)
  --gateway URL     HTTP gateway prefix (default: https://ipfs.io/ipfs/)
  --output FILE     Path to save file (default: template name from JSON or <CID>.img)
  --help            Show this help

Behavior:
  - Prefers the `ipfs` CLI if available (uses `ipfs cat`), otherwise uses curl against a gateway.
  - If the JSON includes a sha256 hash in `template.hash` (format: sha256:<hex>), the downloaded
    file will be verified automatically.
EOF
}

CID=""
GATEWAY="ipfs.dweb.link"
OUTFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cid) CID="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --output) OUTFILE="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    -h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Helper: read field from JSON using jq if available, else use simple sed/grep
json_read() {
  local key="$1"
  # Use jq unconditionally (assume jq is available)
  jq -r "$key // empty" "$JSON_PATH" 2>/dev/null || true
}

if [[ -z "$CID" ]]; then
  if [[ -f "$JSON_PATH" ]]; then
    CID=$(json_read '.template.ipfs.cid_v1')
    if [[ -z "$CID" ]]; then
      echo "No CID found in $JSON_PATH (field .template.ipfs.cid_v1). Provide --cid." >&2
      exit 3
    fi
  else
    echo "$JSON_PATH not found and --cid not provided." >&2
    exit 4
  fi
fi

# Default outfile from JSON template.name if not given
if [[ -z "$OUTFILE" ]]; then
  NAME_FROM_JSON=$(json_read '.template.name' || true)
  if [[ -n "$NAME_FROM_JSON" && "$NAME_FROM_JSON" != "null" ]]; then
    OUTFILE="/tmp/$NAME_FROM_JSON"
  else
    OUTFILE="/tmp/${CID}.img"
  fi
fi

# Helper function to calculate sha256 hash
calculate_hash() {
  local file="$1"
  # send progress message to stderr so stdout is only the hash (suitable for command substitution)
  echo "Calculating sha256 hash for $file ..." >&2
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

# Check if file exists and verify hash
if [[ -f "$OUTFILE" ]]; then
  echo "File already exists: $OUTFILE"
  HASH_FULL=$(json_read '.template.hash' || true)
  if [[ -n "$HASH_FULL" && "$HASH_FULL" != "null" && "$HASH_FULL" == sha256:* ]]; then
    EXPECTED=${HASH_FULL#sha256:}
    ACTUAL=$(calculate_hash "$OUTFILE")
    if [[ -n "$ACTUAL" && "$ACTUAL" == "$EXPECTED" ]]; then
      echo "Existing file hash matches. Skipping download."
      exit 0
    else
      echo "Existing file hash mismatch. Will download fresh copy."
    fi
  else
    echo "No valid hash provided in JSON. Will download fresh copy."
  fi
fi

echo "Downloading IPFS CID: $CID"
echo "Saving to: $OUTFILE"

# Check for ipfs CLI
if command -v ipfs >/dev/null 2>&1; then
  echo "Using local ipfs CLI to fetch..."
  # ipfs cat writes to stdout; redirect to outfile
  if ipfs cat "$CID" > "$OUTFILE"; then
    echo "Downloaded via ipfs CLI."
  else
    echo "ipfs CLI failed to fetch $CID" >&2
    exit 5
  fi
else
  URL="https://${CID}.${GATEWAY}"
  echo "Using HTTP gateway: $URL"
  # Use curl with fail and follow redirects
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$OUTFILE" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$OUTFILE" "$URL"
  else
    echo "Neither curl nor wget nor ipfs was found on PATH. Cannot download." >&2
    exit 6
  fi
fi

# Optional verification: check sha256 if provided
HASH_FULL=$(json_read '.template.hash' || true)
if [[ -n "$HASH_FULL" && "$HASH_FULL" != "null" ]]; then
  echo "Verifying hash..."
  if [[ "$HASH_FULL" == sha256:* ]]; then
    EXPECTED=${HASH_FULL#sha256:}
    ACTUAL=$(calculate_hash "$OUTFILE")
    if [[ -n "$ACTUAL" ]]; then
      if [[ "$ACTUAL" == "$EXPECTED" ]]; then
        echo "sha256 verification passed."
      else
        echo "sha256 mismatch: expected $EXPECTED but got $ACTUAL" >&2
        exit 7
      fi
    fi
  else
    echo "Unknown hash algorithm in JSON: $HASH_FULL (only sha256:<hex> supported currently)" >&2
  fi
else
  echo "No hash provided in JSON; skipping verification."
fi

echo "Done. File saved to: $OUTFILE"
