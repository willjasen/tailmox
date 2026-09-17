#!/usr/bin/env bash
set -Eeuo pipefail

# Stage the Tailmox image helpers from a local checkout and run them on a
# Proxmox host over SSH. The remote builder performs all Proxmox safety checks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $0 [--host HOST] [CREATE-VM-TEMPLATE OPTIONS]

Connect to a Proxmox host as root, stage the image helpers temporarily, and
run create-vm-template.sh there. HOST defaults to pve-a2.

Examples:
  $0
  $0 --storage local-zfs --bridge vmbr0
  $0 --host pve-a2 --clone-count 3

All options other than --host are passed to create-vm-template.sh.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

HOST="${TAILMOX_PVE_HOST:-pve-a2}"
REMOTE_DIR=""
BUILDER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      HOST="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      BUILDER_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
  die "--host contains unsupported characters"

require_command ssh
require_command scp

SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10)
REMOTE="root@$HOST"

cleanup() {
  local exit_code=$?

  if [[ "$REMOTE_DIR" == /tmp/tailmox-vm-image.* ]]; then
    ssh "${SSH_OPTIONS[@]}" "$REMOTE" "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}
trap cleanup EXIT

printf 'Connecting to %s and preparing a temporary workspace...\n' "$REMOTE"
REMOTE_DIR=$(ssh "${SSH_OPTIONS[@]}" "$REMOTE" \
  'mktemp -d /tmp/tailmox-vm-image.XXXXXX')
[[ "$REMOTE_DIR" == /tmp/tailmox-vm-image.* ]] ||
  die "The remote host returned an unsafe temporary path"

scp "${SSH_OPTIONS[@]}" \
  "$SCRIPT_DIR/create-vm-template.sh" \
  "$SCRIPT_DIR/download-template.sh" \
  "$SCRIPT_DIR/template.json" \
  "$REMOTE:$REMOTE_DIR/"

REMOTE_COMMAND=(bash "$REMOTE_DIR/create-vm-template.sh")
REMOTE_COMMAND+=("${BUILDER_ARGS[@]}")
printf -v REMOTE_COMMAND_QUOTED '%q ' "${REMOTE_COMMAND[@]}"

printf 'Setting up the Tailmox VM image on %s...\n' "$HOST"
ssh "${SSH_OPTIONS[@]}" "$REMOTE" "$REMOTE_COMMAND_QUOTED"
