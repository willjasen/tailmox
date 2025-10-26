#!/usr/bin/env bash
set -euo pipefail

# create-vm-template.sh
# Create a Proxmox VM from the downloaded .qcow2 template
# Usage: ./create-vm.sh --node NODE [--vmid ID] [--name NAME] [--template FILE]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_PATH="$SCRIPT_DIR/template.json"

usage() {
  cat <<EOF
Usage: $0 [--vmid ID] [--name NAME] [--template FILE]

Optional:
  --vmid ID       VM ID to use (default: next available ID)
  --name NAME     Name for the VM (default: tailmox-test)
  --template FILE Path to the .qcow2 template (default: from template.json)
  --help          Show this help
EOF
}

# Default values
VMID=""
NAME="tailmox-test"
TEMPLATE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# Helper: read field from JSON using jq
json_read() {
  local key="$1"
  jq -r "$key // empty" "$JSON_PATH" 2>/dev/null || true
}

# If template not specified, get default from JSON
if [[ -z "$TEMPLATE" ]]; then
  if [[ ! -f "$JSON_PATH" ]]; then
    echo "Error: template.json not found and --template not specified" >&2
    exit 1
  fi
  TEMPLATE_NAME=$(json_read ".template.versions.uncompressed.name")
  if [[ -z "$TEMPLATE_NAME" ]]; then
    echo "Error: Could not read template name from template.json" >&2
    exit 1
  fi
  TEMPLATE="/tmp/$TEMPLATE_NAME"
fi

# Verify template file exists
if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: Template file not found: $TEMPLATE" >&2
  echo "Please run download-template.sh first" >&2
  exit 1
fi

# Get next available VMID if not specified
if [[ -z "$VMID" ]]; then
  echo "Finding next available VMID..."
  VMID=$(pvesh get /cluster/nextid)
  if [[ -z "$VMID" ]]; then
    echo "Error: Failed to get next available VMID" >&2
    exit 1
  fi
  echo "Using VMID: $VMID"
fi

# Create a new VM
echo "Creating VM $VMID ($NAME)..."

# Import the disk
echo "Importing disk image..."
qm importdisk "$VMID" "$TEMPLATE" "zfs" || {
  echo "Error: Failed to import disk" >&2
  exit 1
}

# Create the VM with basic configuration
qm create "$VMID" \
  --name "$NAME" \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --serial0 socket \
  --vga serial0 \
  --onboot 1 \
  --boot c --bootdisk scsi0 \
  --ostype l26 \
  --agent 1 \
  --tablet 0 \
  || {
    echo "Error: Failed to create VM" >&2
    exit 1
  }

# Attach the imported disk
qm set "$VMID" --scsi0 "local-lvm:vm-${VMID}-disk-0" || {
  echo "Error: Failed to attach disk" >&2
  exit 1
}

echo "VM $VMID ($NAME) created successfully"
echo "You can now start the VM with: qm start $VMID"