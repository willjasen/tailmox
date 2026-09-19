#!/usr/bin/env bash
set -Eeuo pipefail

# Download and unattended-install a fresh nested Proxmox test VM.
# This is test-environment tooling and must run on the outer Proxmox node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/proxmox-iso.json"
WORK_DIR="${TAILMOX_ISO_WORK_DIR:-}"
KEEP_WORK=false
VMID=""
NAME="tailmox-image"
ISO_URL=""
ISO_SHA256=""
STORAGE=""
ISO_STORAGE="local"
BRIDGE="vlan3"
MEMORY="4096"
CORES="4"
CPU_TYPE="host"
DISK_SIZE="64"
START=false
WAIT_FOR_AGENT=false
ROOT_PASSWORD_FILE="${TAILMOX_PVE_ROOT_PASSWORD_FILE:-}"
ROOT_PASSWORD_HASH="${TAILMOX_PVE_ROOT_PASSWORD_HASH:-}"
HOSTNAME="tailmox-image"

usage() {
  cat <<EOF
Usage: $0 --iso-url URL --iso-sha256 HASH [OPTIONS]

Create a new VM and install Proxmox VE from an unattended, prepared ISO.
The VM is stopped after creation unless --start is supplied.

Options:
  --iso-url URL       Official Proxmox ISO URL (or manifest value)
  --iso-sha256 HASH  Expected ISO SHA-256 (or manifest value)
  --vmid ID           New VM ID (default: next available ID)
  --name NAME         VM name (default: tailmox-image)
  --hostname NAME     Installed guest hostname (default: tailmox-image)
  --storage NAME      VM disk storage (default: first active image storage)
  --iso-storage NAME  ISO storage (default: local)
  --bridge NAME       Outer network bridge (default: vlan3)
  --memory MIB        VM memory (default: 4096)
  --cores COUNT       VM CPU cores (default: 4)
  --cpu TYPE          VM CPU type (default: host)
  --disk-size GiB    Installation disk size (default: 64)
  --root-password-file FILE
                      File containing the installer root password
  --root-password-hash HASH
                      Precomputed SHA-512 crypt root password hash
  --work-dir DIR      Directory for downloaded/prepared installer files
  --start             Start the VM after creating it
  --wait-for-agent    With --start, wait for QEMU guest agent availability
  --keep-work        Keep downloaded/prepared ISO files for inspection
  --help              Show this help

The password may also be supplied with TAILMOX_PVE_ROOT_PASSWORD_FILE or
TAILMOX_PVE_ROOT_PASSWORD_HASH. Passwords are never written to VM notes.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

json_read() {
  local key="$1"
  jq -r "$key // empty" "$MANIFEST" 2>/dev/null || true
}

active_storages() {
  local content="$1"
  pvesm status --content "$content" --enabled 1 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1}'
}

vm_name_exists() {
  local name="$1"
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null |
    jq -e --arg name "$name" '.[] | select(.name == $name)' >/dev/null
}

wait_for_agent() {
  local attempts=0
  while ((attempts < 60)); do
    if qm agent "$VMID" ping >/dev/null 2>&1; then
      printf 'QEMU guest agent is available for VM %s.\n' "$VMID"
      return 0
    fi
    sleep 5
    attempts=$((attempts + 1))
  done
  die "Timed out waiting for QEMU guest agent on VM $VMID"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso-url) [[ $# -ge 2 ]] || die "--iso-url requires a value"; ISO_URL="$2"; shift 2 ;;
    --iso-sha256) [[ $# -ge 2 ]] || die "--iso-sha256 requires a value"; ISO_SHA256="$2"; shift 2 ;;
    --vmid) [[ $# -ge 2 ]] || die "--vmid requires a value"; VMID="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || die "--name requires a value"; NAME="$2"; shift 2 ;;
    --hostname) [[ $# -ge 2 ]] || die "--hostname requires a value"; HOSTNAME="$2"; shift 2 ;;
    --storage) [[ $# -ge 2 ]] || die "--storage requires a value"; STORAGE="$2"; shift 2 ;;
    --iso-storage) [[ $# -ge 2 ]] || die "--iso-storage requires a value"; ISO_STORAGE="$2"; shift 2 ;;
    --bridge) [[ $# -ge 2 ]] || die "--bridge requires a value"; BRIDGE="$2"; shift 2 ;;
    --memory) [[ $# -ge 2 ]] || die "--memory requires a value"; MEMORY="$2"; shift 2 ;;
    --cores) [[ $# -ge 2 ]] || die "--cores requires a value"; CORES="$2"; shift 2 ;;
    --cpu) [[ $# -ge 2 ]] || die "--cpu requires a value"; CPU_TYPE="$2"; shift 2 ;;
    --disk-size) [[ $# -ge 2 ]] || die "--disk-size requires a value"; DISK_SIZE="$2"; shift 2 ;;
    --root-password-file) [[ $# -ge 2 ]] || die "--root-password-file requires a value"; ROOT_PASSWORD_FILE="$2"; shift 2 ;;
    --root-password-hash) [[ $# -ge 2 ]] || die "--root-password-hash requires a value"; ROOT_PASSWORD_HASH="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; WORK_DIR="$2"; KEEP_WORK=true; shift 2 ;;
    --start) START=true; shift ;;
    --wait-for-agent) WAIT_FOR_AGENT=true; shift ;;
    --keep-work) KEEP_WORK=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_command curl
require_command sha256sum
require_command jq
require_command pvesh
require_command pvesm
require_command qm
require_command ip
require_command proxmox-auto-install-assistant
require_command openssl
[[ "$(id -u)" -eq 0 ]] || die "Run this script as root on an outer Proxmox node"
[[ -f "$MANIFEST" ]] || die "Missing ISO manifest: $MANIFEST"

[[ -n "$ISO_URL" ]] || ISO_URL="$(json_read '.iso.url')"
[[ -n "$ISO_SHA256" ]] || ISO_SHA256="$(json_read '.iso.sha256')"
[[ "$ISO_URL" =~ ^https:// ]] || die "ISO URL must use HTTPS"
[[ "$ISO_SHA256" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "ISO SHA-256 must be exactly 64 hexadecimal characters"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid VM name"
[[ "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Invalid guest hostname"
[[ "$BRIDGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid bridge"
[[ "$CPU_TYPE" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Invalid CPU type"
[[ "$MEMORY" =~ ^[1-9][0-9]*$ ]] || die "Memory must be a positive integer"
[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "Cores must be a positive integer"
[[ "$DISK_SIZE" =~ ^[1-9][0-9]*$ ]] || die "Disk size must be a positive integer"
if [[ -n "$VMID" ]]; then
  [[ "$VMID" =~ ^[1-9][0-9]*$ ]] || die "VM ID must be a positive integer"
else
  VMID="$(pvesh get /cluster/nextid)"
fi

if [[ -z "$ROOT_PASSWORD_HASH" ]]; then
  [[ -n "$ROOT_PASSWORD_FILE" && -f "$ROOT_PASSWORD_FILE" ]] ||
    die "Provide --root-password-file or --root-password-hash"
  ROOT_PASSWORD="$(head -n 1 "$ROOT_PASSWORD_FILE")"
  [[ -n "$ROOT_PASSWORD" ]] || die "Root password file is empty"
  ROOT_PASSWORD_HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"
  unset ROOT_PASSWORD
fi
[[ "$ROOT_PASSWORD_HASH" == \$6\$* ]] || die "Root password hash must use SHA-512 crypt"
[[ "$WAIT_FOR_AGENT" != true || "$START" == true ]] ||
  die "--wait-for-agent requires --start"

if [[ -z "$STORAGE" ]]; then
  STORAGE="$(active_storages images | head -n 1)"
fi
[[ -n "$STORAGE" ]] || die "No active VM image storage is available"
printf '%s\n' "$STORAGE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
  die "Invalid VM image storage"
printf '%s\n' "$ISO_STORAGE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
  die "Invalid ISO storage"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge '$BRIDGE' does not exist"
qm status "$VMID" >/dev/null 2>&1 && die "VM ID $VMID already exists"
vm_name_exists "$NAME" && die "A VM or template named '$NAME' already exists"

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d)"
  KEEP_WORK=false
else
  mkdir -p "$WORK_DIR"
fi
cleanup() {
  local exit_code=$?
  if [[ "$KEEP_WORK" != true ]]; then
    rm -rf "$WORK_DIR"
  else
    printf 'Installation work files retained at %s\n' "$WORK_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

ISO_NAME="$(basename "${ISO_URL%%\?*}")"
[[ "$ISO_NAME" =~ \.iso$ ]] || ISO_NAME="proxmox-ve.iso"
SOURCE_ISO="$WORK_DIR/$ISO_NAME"
PREPARED_ISO="$WORK_DIR/prepared-$ISO_NAME"
ANSWER_FILE="$WORK_DIR/answer.toml"
FIRST_BOOT="$WORK_DIR/tailmox-first-boot.sh"

printf 'Downloading Proxmox ISO to %s...\n' "$SOURCE_ISO"
curl --fail --location --proto '=https' --tlsv1.2 --output "$SOURCE_ISO" "$ISO_URL"
printf '%s  %s\n' "$ISO_SHA256" "$SOURCE_ISO" | sha256sum --check --status ||
  die "Proxmox ISO SHA-256 verification failed"

cat >"$ANSWER_FILE" <<EOF
[global]
keyboard = "en-us"
country = "us"
fqdn = "$HOSTNAME"
timezone = "America/New_York"
root-password-hashed = "$ROOT_PASSWORD_HASH"
reboot-mode = "reboot"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
EOF

cat >"$FIRST_BOOT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect
hostnamectl set-hostname "$HOSTNAME"
if grep -qE '^iface vmbr0 inet ' /etc/network/interfaces; then
  sed -i -E 's/^iface vmbr0 inet .*/iface vmbr0 inet dhcp/' /etc/network/interfaces
fi
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
systemctl enable qemu-guest-agent.service serial-getty@ttyS0.service resolvconf.service
cat >/etc/tailmox-image-release <<'RELEASE'
TAILMOX_IMAGE_RELEASE=0
TAILMOX_PREPARE_API=0
RELEASE
chmod 0644 /etc/tailmox-image-release
systemctl restart qemu-guest-agent.service || true
EOF
chmod 0755 "$FIRST_BOOT"

proxmox-auto-install-assistant prepare-iso "$SOURCE_ISO" \
  --fetch-from iso \
  --answer-file "$ANSWER_FILE" \
  --on-first-boot "$FIRST_BOOT" \
  --output "$PREPARED_ISO"

ISO_TARGET="$(pvesm path "$ISO_STORAGE:iso/$ISO_NAME")"
mkdir -p "$(dirname "$ISO_TARGET")"
install -m 0644 "$PREPARED_ISO" "$ISO_TARGET"

DESCRIPTION="$(printf '%s\n\n- **Purpose:** Fresh Proxmox test image installed from a verified ISO\n- **ISO URL:** `%s`\n- **ISO SHA-256:** `%s`\n- **Guest hostname:** `%s`\n- **Network:** VirtIO on `%s`\n- **Consoles:** `serial0: socket`, `vga: std`\n- **Guest agent:** enabled\n- **State:** Installer media attached; boot only with `--start`' \
  '## Tailmox ISO-installed Development Image' "$ISO_URL" "$ISO_SHA256" "$HOSTNAME" "$BRIDGE")"
qm create "$VMID" \
  --name "$NAME" \
  --description "$DESCRIPTION" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --cpu "$CPU_TYPE" \
  --net0 "virtio,bridge=$BRIDGE" \
  --scsi0 "$STORAGE:$DISK_SIZE" \
  --ide2 "$ISO_STORAGE:iso/$ISO_NAME,media=cdrom" \
  --serial0 socket \
  --vga std \
  --agent 1 \
  --boot 'order=ide2;scsi0' \
  --ostype l26 \
  --onboot 0 \
  --tablet 0 \
  --tags tailmox

printf 'VM %s (%s) created with unattended installer media.\n' "$VMID" "$NAME"
if [[ "$START" == true ]]; then
  qm start "$VMID"
  printf 'VM %s started. The first-boot hook installs guest dependencies and enables qm terminal access.\n' "$VMID"
  [[ "$WAIT_FOR_AGENT" == true ]] && wait_for_agent
else
  printf 'VM remains stopped. Start it with: qm start %s\n' "$VMID"
fi
