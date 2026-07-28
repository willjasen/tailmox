#!/usr/bin/env bash
set -Eeuo pipefail

# Create a Proxmox VM template from the Tailmox qcow2 image and optionally
# create linked clones. This script must run directly on a Proxmox node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_PATH="$SCRIPT_DIR/template.json"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --vmid ID          Template VM ID (default: next available ID)
  --name NAME        Template name (default: tailmox-template)
  --template FILE    Source qcow2 file (default: value from template.json)
  --storage NAME     Proxmox image storage (default: first active image storage)
  --bridge NAME      Proxmox network bridge (default: vmbr0)
  --memory MIB       Template memory in MiB (default: 1024)
  --cores COUNT      Template CPU core count (default: 1)
  --cpu TYPE         Template CPU type (default: host)
  --onboot 0|1       Start clones when the host boots (default: 0)
  --clone-count N    Create N linked clones after the template (default: 0)
  --clone-prefix P   Clone name prefix (default: tailmox)
  --help              Show this help

Examples:
  $0 --storage local-zfs
  $0 --storage local-zfs --bridge vmbr1 --clone-count 3
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_positive_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer"
}

require_nonnegative_integer() {
  local label="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a non-negative integer"
}

json_read() {
  local key="$1"
  jq -r "$key // empty" "$JSON_PATH" 2>/dev/null || true
}

active_image_storages() {
  pvesm status --content images --enabled 1 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1}'
}

vm_name_exists() {
  local name="$1"

  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null |
    jq -e --arg name "$name" '.[] | select(.name == $name)' >/dev/null
}

VMID=""
NAME="tailmox-template"
TEMPLATE=""
MANAGED_TEMPLATE=false
STORAGE=""
BRIDGE="vmbr0"
MEMORY="1024"
CORES="1"
CPU_TYPE="host"
ONBOOT="0"
CLONE_COUNT="0"
CLONE_PREFIX="tailmox"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)
      [[ $# -ge 2 ]] || die "--vmid requires a value"
      VMID="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      NAME="$2"
      shift 2
      ;;
    --template)
      [[ $# -ge 2 ]] || die "--template requires a value"
      TEMPLATE="$2"
      shift 2
      ;;
    --storage)
      [[ $# -ge 2 ]] || die "--storage requires a value"
      STORAGE="$2"
      shift 2
      ;;
    --bridge)
      [[ $# -ge 2 ]] || die "--bridge requires a value"
      BRIDGE="$2"
      shift 2
      ;;
    --memory)
      [[ $# -ge 2 ]] || die "--memory requires a value"
      MEMORY="$2"
      shift 2
      ;;
    --cores)
      [[ $# -ge 2 ]] || die "--cores requires a value"
      CORES="$2"
      shift 2
      ;;
    --cpu)
      [[ $# -ge 2 ]] || die "--cpu requires a value"
      CPU_TYPE="$2"
      shift 2
      ;;
    --onboot)
      [[ $# -ge 2 ]] || die "--onboot requires a value"
      ONBOOT="$2"
      shift 2
      ;;
    --clone-count)
      [[ $# -ge 2 ]] || die "--clone-count requires a value"
      CLONE_COUNT="$2"
      shift 2
      ;;
    --clone-prefix)
      [[ $# -ge 2 ]] || die "--clone-prefix requires a value"
      CLONE_PREFIX="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_command jq
require_command pvesh
require_command pvesm
require_command qm
require_command ip

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root on a Proxmox node"
[[ -f "$JSON_PATH" ]] || die "Missing metadata file: $JSON_PATH"
[[ -n "$NAME" ]] || die "--name cannot be empty"
[[ -n "$BRIDGE" ]] || die "--bridge cannot be empty"
[[ -n "$CPU_TYPE" ]] || die "--cpu cannot be empty"
[[ -n "$CLONE_PREFIX" ]] || die "--clone-prefix cannot be empty"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "--name contains unsupported characters"
[[ "$BRIDGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "--bridge contains unsupported characters"
[[ "$CLONE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "--clone-prefix contains unsupported characters"
if [[ -n "$STORAGE" && ! "$STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "--storage contains unsupported characters"
fi
require_positive_integer "--memory" "$MEMORY"
require_positive_integer "--cores" "$CORES"
[[ "$ONBOOT" == "0" || "$ONBOOT" == "1" ]] ||
  die "--onboot must be 0 or 1"
require_nonnegative_integer "--clone-count" "$CLONE_COUNT"
if [[ -n "$VMID" ]]; then
  require_positive_integer "--vmid" "$VMID"
fi

if [[ -z "$TEMPLATE" ]]; then
  TEMPLATE_NAME=$(json_read ".template.versions.uncompressed.name")
  [[ -n "$TEMPLATE_NAME" ]] ||
    die "Could not read the uncompressed template name from template.json"
  TEMPLATE="/tmp/$TEMPLATE_NAME"
  MANAGED_TEMPLATE=true
fi

if [[ "$MANAGED_TEMPLATE" == true ]]; then
  echo "Downloading or verifying the managed template image..."
  "$SCRIPT_DIR/download-template.sh" --version compressed --output "$TEMPLATE"
fi

[[ -f "$TEMPLATE" ]] || die "Template file not found: $TEMPLATE"

AVAILABLE_STORAGES=()
while IFS= read -r storage_name; do
  AVAILABLE_STORAGES+=("$storage_name")
done < <(active_image_storages)
[[ "${#AVAILABLE_STORAGES[@]}" -gt 0 ]] ||
  die "No enabled, active Proxmox storage with 'images' content is available"

if [[ -z "$STORAGE" ]]; then
  STORAGE="${AVAILABLE_STORAGES[0]}"
  echo "Using automatically selected image storage: $STORAGE"
elif ! printf '%s\n' "${AVAILABLE_STORAGES[@]}" | grep -Fxq "$STORAGE"; then
  die "Storage '$STORAGE' is not enabled and active for VM images"
fi

ip link show "$BRIDGE" >/dev/null 2>&1 ||
  die "Network bridge '$BRIDGE' does not exist on this node"

if [[ -z "$VMID" ]]; then
  echo "Finding the next available VM ID..."
  VMID=$(pvesh get /cluster/nextid)
  require_positive_integer "Next VM ID" "$VMID"
fi

if qm status "$VMID" >/dev/null 2>&1; then
  die "VM ID $VMID already exists"
fi

if vm_name_exists "$NAME"; then
  die "A VM or template named '$NAME' already exists"
fi

for ((index = 1; index <= CLONE_COUNT; index++)); do
  CLONE_NAME="${CLONE_PREFIX}${index}"
  [[ "$CLONE_NAME" != "$NAME" ]] ||
    die "Planned clone name '$CLONE_NAME' conflicts with the template name"
  if vm_name_exists "$CLONE_NAME"; then
    die "A VM named '$CLONE_NAME' already exists"
  fi
done

TEMPLATE_CREATED=false
cleanup_failed_template() {
  local exit_code=$?

  if [[ "$exit_code" -ne 0 && "$TEMPLATE_CREATED" == true ]]; then
    echo "Template creation failed; removing incomplete VM $VMID..." >&2
    qm destroy "$VMID" --purge 1 >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}
trap cleanup_failed_template EXIT

echo "Creating VM $VMID ($NAME)..."
qm create "$VMID" \
  --name "$NAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --cpu "$CPU_TYPE" \
  --net0 "virtio,bridge=$BRIDGE" \
  --serial0 socket \
  --vga std \
  --onboot "$ONBOOT" \
  --boot c \
  --bootdisk scsi0 \
  --ostype l26 \
  --agent 1 \
  --tablet 0 \
  --tags tailmox
TEMPLATE_CREATED=true

echo "Importing the disk image into $STORAGE..."
qm importdisk "$VMID" "$TEMPLATE" "$STORAGE"

IMPORTED_VOLUME=$(
  qm config "$VMID" |
    sed -n 's/^unused[0-9][0-9]*: \([^,]*\).*/\1/p' |
    head -n 1
)
[[ -n "$IMPORTED_VOLUME" ]] ||
  die "The disk import completed but no imported volume was found in VM $VMID"

qm set "$VMID" --scsi0 "$IMPORTED_VOLUME"
qm template "$VMID"
TEMPLATE_CREATED=false

echo "VM template $VMID ($NAME) created successfully."

if [[ "$CLONE_COUNT" -eq 0 ]]; then
  exit 0
fi

echo "Creating $CLONE_COUNT linked clone(s)..."
for ((index = 1; index <= CLONE_COUNT; index++)); do
  CLONE_NAME="${CLONE_PREFIX}${index}"
  CLONE_VMID=$(pvesh get /cluster/nextid)
  require_positive_integer "Next clone VM ID" "$CLONE_VMID"

  qm clone "$VMID" "$CLONE_VMID" \
    --name "$CLONE_NAME" \
    --full 0
  echo "Created linked clone $CLONE_VMID ($CLONE_NAME)."
done

echo "Template and linked-clone deployment completed successfully."
