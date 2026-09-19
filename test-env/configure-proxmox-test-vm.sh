#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: configure-proxmox-test-vm.sh --vmid ID [--bridge BRIDGE] [--start]

Configure a nested Proxmox VM for Tailmox testing. The VM is not started
unless --start is supplied.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

VMID=""
BRIDGE="vlan3"
START=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)
      [[ $# -ge 2 ]] || die "--vmid requires a value"
      VMID="$2"
      shift 2
      ;;
    --bridge)
      [[ $# -ge 2 ]] || die "--bridge requires a value"
      BRIDGE="$2"
      shift 2
      ;;
    --start)
      START=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$VMID" =~ ^[0-9]+$ ]] || die "--vmid must be a numeric VM ID"
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--bridge contains unsupported characters"

require_command qm
qm status "$VMID" >/dev/null 2>&1 || die "VM $VMID was not found"

qm set "$VMID" \
  --serial0 socket \
  --vga std \
  --agent 1 \
  --net0 "virtio,bridge=$BRIDGE"

if [[ "$START" == true ]]; then
  qm start "$VMID"
fi

printf 'Configured VM %s: serial0=socket, vga=std, agent=1, bridge=%s\n' \
  "$VMID" "$BRIDGE"
