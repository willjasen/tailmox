#!/usr/bin/env bash
set -euo pipefail

# tailmox-download-template.sh
# Download the template image referenced in tailmox-template.json from IPFS.
# Usage: ./tailmox-download-template.sh [--gateway URL] [--output FILE]
# If --cid is omitted, the script reads `template.ipfs` from tailmox-template.json located
# next to this script. If `template.name` is present it will be used as the default output filename.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_PATH="$SCRIPT_DIR/template.json"

usage() {
  cat <<EOF
Usage: $0 [--gateway URL] [--output FILE] [--version VERSION]

Options:
  --gateway URL     HTTP gateway host (default: ipfs.dweb.link; used as <CID>.<gateway>)
  --output FILE     Path to save file (default: template name from JSON or <CID>.img)
  --version VER     Version to download (compressed|uncompressed, default: uncompressed)
  --help            Show this help

Behavior:
  - Prefers the \`ipfs\` CLI if available (uses \`ipfs cat\`), otherwise uses curl/wget against a gateway.
  - The CID is read from template.json next to this script (.template.ipfs.cid_v1).
  - If the JSON includes a sha256 hash in \`template.hash\` (format: sha256:<hex>), the downloaded
    file will be verified automatically.
EOF
}

CID=""
GATEWAY="ipfs.dweb.link"
OUTFILE=""
VERSION="uncompressed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway) GATEWAY="$2"; shift 2 ;;
    --output) OUTFILE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    -h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Validate version
if [[ "$VERSION" != "compressed" && "$VERSION" != "uncompressed" ]]; then
  echo "Invalid version: $VERSION. Must be 'compressed' or 'uncompressed'" >&2
  exit 2
fi

# Helper: read field from JSON using jq if available, else use simple sed/grep
json_read() {
  local key="$1"
  # Use jq unconditionally (assume jq is available)
  jq -r "$key // empty" "$JSON_PATH" 2>/dev/null || true
}

# Require template.json and read CID from it (no --cid option anymore)
if [[ ! -f "$JSON_PATH" ]]; then
  echo "$JSON_PATH not found. This script requires template.json next to the script." >&2
  exit 4
fi

# Update JSON reading paths to use version-specific paths
CID=$(json_read ".template.versions.$VERSION.ipfs.cid_v1")
if [[ -z "$CID" || "$CID" == "null" ]]; then
  echo "No CID found in $JSON_PATH for version $VERSION" >&2
  exit 3
fi

# Default outfile from JSON template.name if not given
if [[ -z "$OUTFILE" ]]; then
  NAME_FROM_JSON=$(json_read ".template.versions.$VERSION.name" || true)
  if [[ -n "$NAME_FROM_JSON" && "$NAME_FROM_JSON" != "null" ]]; then
    OUTFILE="/tmp/$NAME_FROM_JSON"
  else
    OUTFILE="/tmp/${CID}.img"
  fi
fi

# --- Added: support xz_compressed flag and derive download vs final paths ---
XZ_FLAG=$(json_read ".template.versions.$VERSION.xz_compressed" || true)
if [[ "$XZ_FLAG" == "true" || "$XZ_FLAG" == "1" ]]; then
  if [[ "$OUTFILE" == *.tar.xz ]]; then
    DOWNLOAD_PATH="$OUTFILE"
    FINAL_OUTFILE="${OUTFILE%.tar.xz}"
  else
    DOWNLOAD_PATH="${OUTFILE}.tar.xz"
    FINAL_OUTFILE="$OUTFILE"
  fi
else
  DOWNLOAD_PATH="$OUTFILE"
  FINAL_OUTFILE="$OUTFILE"
fi

# Echo the derived paths
echo "Download path: $DOWNLOAD_PATH"
echo "Final outfile: $FINAL_OUTFILE"

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

# Function: decompress xz file
decompress_xz() {
  local src="$1" dst="$2"
  echo "Decompressing $src -> $dst"
  if [[ "$src" == *.tar.xz ]]; then
    if command -v tar >/dev/null 2>&1; then
      tar -xJf "$src" -C "/tmp"
      return $?
    else
      echo "tar/xz is not available to decompress $src" >&2
      return 2
    fi
  else
    echo "File $src is not an .tar.xz archive" >&2
    return 3
  fi
}

# Check if final file exists and verify hash
if [[ -f "$FINAL_OUTFILE" ]]; then
  echo "File already exists: $FINAL_OUTFILE"
  HASH_FULL=$(json_read ".template.versions.$VERSION.hash" || true)
  if [[ -n "$HASH_FULL" && "$HASH_FULL" != "null" && "$HASH_FULL" == sha256:* ]]; then
    EXPECTED=${HASH_FULL#sha256:}
    ACTUAL=$(calculate_hash "$FINAL_OUTFILE")
    if [[ -n "$ACTUAL" && "$ACTUAL" == "$EXPECTED" ]]; then
      echo "Existing file hash matches. Skipping download."
      exit 0
    else
      echo "Existing file hash mismatch. Will download fresh copy."
    fi
  else
    echo "No valid hash provided in JSON. Will download fresh copy."
  fi
elif [[ "$XZ_FLAG" == "true" && -f "$DOWNLOAD_PATH" ]]; then
  echo "Found existing compressed file: $DOWNLOAD_PATH. Attempting to decompress."
  if decompress_xz "$DOWNLOAD_PATH" "$FINAL_OUTFILE"; then
    echo "Decompressed existing file to $FINAL_OUTFILE"
    HASH_FULL=$(json_read ".template.versions.$VERSION.hash" || true)
    if [[ -n "$HASH_FULL" && "$HASH_FULL" != "null" && "$HASH_FULL" == sha256:* ]]; then
      EXPECTED=${HASH_FULL#sha256:}
      ACTUAL=$(calculate_hash "$FINAL_OUTFILE")
      if [[ -n "$ACTUAL" && "$ACTUAL" == "$EXPECTED" ]]; then
        echo "Existing (decompressed) file hash matches. Skipping download."
        # rm -f "$DOWNLOAD_PATH" || true
        exit 0
      else
        echo "Existing decompressed hash mismatch. Will download fresh copy."
      fi
    else
      echo "No valid hash provided in JSON. Will download fresh copy."
    fi
  else
    echo "Failed to decompress existing compressed file. Will download fresh copy."
  fi
fi

# --- Ensure target directory exists and has enough free space (use DOWNLOAD_PATH) ---
DIR="$(dirname "$DOWNLOAD_PATH")"
if [[ ! -d "$DIR" ]]; then
  mkdir -p "$DIR" || { echo "Cannot create directory $DIR" >&2; exit 8; }
fi

echo "Checking if there is enough free space in $DIR..."
SIZE_BYTES=$(json_read ".template.versions.$VERSION.size_in_bytes" || true)
if [[ -n "$SIZE_BYTES" && "$SIZE_BYTES" != "null" ]]; then
  if [[ "$SIZE_BYTES" =~ ^[0-9]+$ ]]; then
    # Get available kilobytes for the filesystem containing DIR, convert to bytes
    AVAIL_KB=$(df -Pk "$DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    AVAIL_BYTES=$(( (${AVAIL_KB:-0} * 1024) + (1024 * 1024 * 1024) )) # Add 1GB buffer
    if (( AVAIL_BYTES < SIZE_BYTES )); then
      echo "Not enough free space in $DIR. Required: $SIZE_BYTES bytes, Available: $AVAIL_BYTES bytes (including 1GB buffer)" >&2
      exit 9
    fi
  else
    echo "Invalid size_in_bytes in JSON: $SIZE_BYTES; skipping space check." >&2
  fi
fi

echo "Downloading IPFS CID: $CID"
echo "Saving to: $DOWNLOAD_PATH"

# Check for ipfs CLI
if command -v ipfs >/dev/null 2>&1; then
  echo "Using local ipfs CLI to fetch..."
  # ipfs cat writes to stdout; redirect to outfile
  if ipfs cat "$CID" > "$DOWNLOAD_PATH"; then
    echo "Downloaded via ipfs CLI."
  else
    echo "ipfs CLI failed to fetch $CID" >&2
    exit 5
  fi
else
  if [[ "$GATEWAY" == "kubo1.risk-mermaid.ts.net" ]]; then
    URL="http://kubo1.risk-mermaid.ts.net:8080/ipfs/${CID}"
  else
    URL="https://${CID}.${GATEWAY}"
  fi
  echo "Using HTTP gateway: $URL"
  # Use curl with fail and follow redirects
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$DOWNLOAD_PATH" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$DOWNLOAD_PATH" "$URL"
  else
    echo "Neither curl nor wget nor ipfs was found on PATH. Cannot download." >&2
    exit 6
  fi
fi

# If xz flag set, decompress downloaded file into FINAL_OUTFILE
if [[ "$XZ_FLAG" == "true" || "$XZ_FLAG" == "1" ]]; then
  if decompress_xz "$DOWNLOAD_PATH" "$FINAL_OUTFILE"; then
    echo "Decompression succeeded: $FINAL_OUTFILE"
    # rm -f "$DOWNLOAD_PATH" || true
  else
    echo "Decompression failed for $DOWNLOAD_PATH" >&2
    exit 10
  fi
fi

# Optional verification: check sha256 if provided (verify FINAL_OUTFILE)
HASH_FULL=$(json_read ".template.versions.$VERSION.hash" || true)
if [[ -n "$HASH_FULL" && "$HASH_FULL" != "null" ]]; then
  echo "Verifying hash..."
  if [[ "$HASH_FULL" == sha256:* ]]; then
    EXPECTED=${HASH_FULL#sha256:}
    ACTUAL=$(calculate_hash "$FINAL_OUTFILE")
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

echo "Done. File saved to: $FINAL_OUTFILE"
