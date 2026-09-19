#!/usr/bin/env bash
set -Eeuo pipefail

# Convert an installed nested Proxmox VM into a template and create linked
# clones. Run this on the outer Proxmox node after guest preparation.

VMID=""
NAME=""
CLONE_COUNT="3"
CLONE_VMID_START="50001"
CLONE_PREFIX="tailmox-t"
SNAPSHOT_NAME="ready-for-testing"
ISO_SHA256=""
VERIFY_REBOOT=false
ROOT_PASSWORD_FILE=""

usage() {
  cat <<EOF
Usage: $0 --vmid ID [OPTIONS]

Options:
  --vmid ID              Installed VM to convert (required)
  --name NAME            Template name (default: current VM name)
  --clone-count N        Linked clones to create (default: 3)
  --clone-vmid-start ID  First linked clone ID (default: 50001)
  --clone-prefix PREFIX  Clone name prefix (default: tailmox-t)
  --snapshot NAME        Initial clone snapshot name (default: ready-for-testing)
  --iso-sha256 HASH      ISO hash to include in template and clone notes
  --verify-reboot        Reboot and verify the guest agent before conversion
  --root-password-file FILE
                         Root password file for the serial-console package check
  --help                 Show this help
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer"
}

require_nonnegative_integer() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer"
}

vm_name_exists() {
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null |
    jq -e --arg name "$1" '.[] | select(.name == $name)' >/dev/null
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) [[ $# -ge 2 ]] || die "--vmid requires a value"; VMID="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || die "--name requires a value"; NAME="$2"; shift 2 ;;
    --clone-count) [[ $# -ge 2 ]] || die "--clone-count requires a value"; CLONE_COUNT="$2"; shift 2 ;;
    --clone-vmid-start) [[ $# -ge 2 ]] || die "--clone-vmid-start requires a value"; CLONE_VMID_START="$2"; shift 2 ;;
    --clone-prefix) [[ $# -ge 2 ]] || die "--clone-prefix requires a value"; CLONE_PREFIX="$2"; shift 2 ;;
    --snapshot) [[ $# -ge 2 ]] || die "--snapshot requires a value"; SNAPSHOT_NAME="$2"; shift 2 ;;
    --iso-sha256) [[ $# -ge 2 ]] || die "--iso-sha256 requires a value"; ISO_SHA256="$2"; shift 2 ;;
    --verify-reboot) VERIFY_REBOOT=true; shift ;;
    --root-password-file) [[ $# -ge 2 ]] || die "--root-password-file requires a value"; ROOT_PASSWORD_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_command qm
require_command pvesh
require_command jq
require_command openssl
require_command expect
[[ "$(id -u)" -eq 0 ]] || die "Run this script as root on an outer Proxmox node"
[[ -n "$VMID" ]] || die "--vmid is required"
require_positive_integer "--vmid" "$VMID"
require_nonnegative_integer "--clone-count" "$CLONE_COUNT"
require_positive_integer "--clone-vmid-start" "$CLONE_VMID_START"
[[ "$CLONE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid clone prefix"
[[ "$SNAPSHOT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid snapshot name"
[[ -z "$ISO_SHA256" || "$ISO_SHA256" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "ISO SHA-256 must be exactly 64 hexadecimal characters"
[[ -n "$ROOT_PASSWORD_FILE" ]] || ROOT_PASSWORD_FILE="${TAILMOX_ROOT_PASSWORD_FILE:-}"
[[ -f "$ROOT_PASSWORD_FILE" ]] || die "A root password file is required for the serial-console package check"

check_packages_over_terminal() {
  local password="$1"
  TAILMOX_ROOT_PASSWORD="$password" expect <<'EXPECT'
set timeout 1800
spawn qm terminal $env(VMID)
expect {
  -re "(?i)(login|username):" { send "root\r"; exp_continue }
  -re "(?i)password:" { send "$env(TAILMOX_ROOT_PASSWORD)\r" }
}
expect -re {[#\$] $}
send -- "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect; apt-get install -y --only-upgrade ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect; systemctl enable --now qemu-guest-agent.service serial-getty@ttyS0.service; if command -v tailscale >/dev/null 2>&1; then tailscale update --yes; else curl -fsSL https://tailscale.com/install.sh | sh; fi; printf '__TAILMOX_PACKAGES_OK__\\n'\r"
expect "__TAILMOX_PACKAGES_OK__"
send -- "exit\r"
expect eof
EXPECT
}

qm status "$VMID" >/dev/null 2>&1 || die "VM $VMID does not exist"
[[ "$(qm status "$VMID" | awk -F': ' '/^status:/ {print $2}')" == "stopped" ]] ||
  die "VM $VMID must be stopped before template conversion"
CONFIG="$(qm config "$VMID")"
grep -q '^template: 1$' <<<"$CONFIG" && IS_TEMPLATE=true || IS_TEMPLATE=false
if [[ "$VERIFY_REBOOT" == true && "$IS_TEMPLATE" != true ]]; then
  qm start "$VMID"
  for attempt in $(seq 1 60); do
    qm agent "$VMID" ping >/dev/null 2>&1 && break
    [[ "$attempt" -eq 60 ]] && die "QEMU guest agent did not become ready after boot"
    sleep 5
  done
  qm reboot "$VMID" >/dev/null 2>&1 || die "Guest reboot failed for VM $VMID"
  for attempt in $(seq 1 60); do
    qm agent "$VMID" ping >/dev/null 2>&1 && break
    [[ "$attempt" -eq 60 ]] && die "QEMU guest agent did not return after reboot"
    sleep 5
  done
  qm terminal "$VMID" </dev/null >/dev/null 2>&1 ||
    die "Serial console could not be opened for VM $VMID"
  qm shutdown "$VMID" --timeout 120 >/dev/null 2>&1 ||
    die "Could not shut down VM $VMID after reboot verification"
  for attempt in $(seq 1 24); do
    [[ "$(qm status "$VMID" | awk -F': ' '/^status:/ {print $2}')" == "stopped" ]] && break
    [[ "$attempt" -eq 24 ]] && die "VM $VMID did not stop after verification"
    sleep 5
  done
  CONFIG="$(qm config "$VMID")"
fi
if [[ "$IS_TEMPLATE" != true ]]; then
  ROOT_PASSWORD="$(head -n 1 "$ROOT_PASSWORD_FILE")"
  [[ -n "$ROOT_PASSWORD" ]] || die "Root password file is empty"
  qm start "$VMID"
  for attempt in $(seq 1 60); do
    qm agent "$VMID" ping >/dev/null 2>&1 && break
    [[ "$attempt" -eq 60 ]] && die "QEMU guest agent did not become ready for package check"
    sleep 5
  done
  VMID="$VMID" check_packages_over_terminal "$ROOT_PASSWORD" ||
    die "Serial-console package check failed"
  qm agent "$VMID" ping >/dev/null 2>&1 ||
    die "QEMU guest agent did not respond after package installation"
  unset ROOT_PASSWORD
  qm shutdown "$VMID" --timeout 120 >/dev/null 2>&1 ||
    die "Could not shut down VM $VMID after package check"
  for attempt in $(seq 1 24); do
    [[ "$(qm status "$VMID" | awk -F': ' '/^status:/ {print $2}')" == "stopped" ]] && break
    [[ "$attempt" -eq 24 ]] && die "VM $VMID did not stop after package check"
    sleep 5
  done
  CONFIG="$(qm config "$VMID")"
fi
if [[ -z "$NAME" ]]; then
  NAME="$(sed -n 's/^name: //p' <<<"$CONFIG")"
fi
[[ -n "$NAME" ]] || die "Could not determine template name"
if [[ "$IS_TEMPLATE" != true ]]; then
  qm set "$VMID" --cores 2 --memory 2048
  if grep -q '^ide2:' <<<"$CONFIG"; then
    qm set "$VMID" --delete ide2
  fi
  TEMPLATE_NOTE="$(printf '%s\n\n- **State:** Prepared source VM converted to reusable template\n- **ISO SHA-256:** `%s`\n- **Consoles:** `serial0: socket`, `vga: std`\n- **Guest agent:** enabled\n- **Linked clones:** `%s`' \
    '## Tailmox Development Template' "$ISO_SHA256" "$CLONE_COUNT")"
  qm set "$VMID" --name "$NAME" --description "$TEMPLATE_NOTE"
  qm template "$VMID"
fi

CLONE_NAMES=()
for ((index = 1; index <= CLONE_COUNT; index++)); do
  CLONE_VMID=$((CLONE_VMID_START + index - 1))
  qm status "$CLONE_VMID" >/dev/null 2>&1 &&
    die "Linked clone VM ID $CLONE_VMID already exists"
  while :; do
    CLONE_NAME="${CLONE_PREFIX}$(openssl rand -hex 2)"
    [[ ! " ${CLONE_NAMES[*]-} " == *" ${CLONE_NAME} "* ]] && break
  done
  vm_name_exists "$CLONE_NAME" && die "VM name '$CLONE_NAME' already exists"
  CLONE_NAMES+=("$CLONE_NAME")
done

for ((index = 1; index <= CLONE_COUNT; index++)); do
  CLONE_VMID=$((CLONE_VMID_START + index - 1))
  CLONE_NAME="${CLONE_NAMES[index-1]}"
  qm clone "$VMID" "$CLONE_VMID" --name "$CLONE_NAME" --full 0
  DESCRIPTION="$(printf '%s\n\n- **VM ID:** `%s`\n- **Hostname:** `%s`\n- **Source template:** `%s` (`%s`)\n- **ISO SHA-256:** `%s`\n- **Network:** inherited from template\n- **Consoles:** `serial0: socket`, `vga: std`\n- **Recovery snapshot:** `%s`' \
    "## Tailmox Development Node $index" "$CLONE_VMID" "$CLONE_NAME" "$VMID" "$NAME" \
    "$ISO_SHA256" "$SNAPSHOT_NAME")"
  qm set "$CLONE_VMID" --description "$DESCRIPTION"
  qm snapshot "$CLONE_VMID" "$SNAPSHOT_NAME" \
    --description "Initial Tailmox test state for linked clone $CLONE_NAME before first boot"
  printf 'Created linked clone %s (%s).\n' "$CLONE_VMID" "$CLONE_NAME"
done

printf 'Template %s (%s) and %s linked clone(s) are ready.\n' \
  "$VMID" "$NAME" "$CLONE_COUNT"
