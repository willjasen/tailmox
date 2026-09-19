#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare a linked clone through the Proxmox guest agent. This is intended for
# images that still have the original static 192.168.123.90 configuration and
# therefore cannot yet be reached over SSH.

usage() {
  cat <<'EOF'
Usage: $0 --vmid ID [OPTIONS]

Options:
  --vmid ID              Proxmox VM ID (required)
  --hostname NAME        Guest hostname (default: tailmox<ID>)
  --ref REF              Tailmox Git ref to deploy (default: dev)
  --service-name NAME    Tailscale service label (default: dev-tailmox)
  --root-password PASS   Alphanumeric root password (optional)
  --timeout SEC          Guest-agent command timeout (default: 300)
  --help                 Show this help
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
HOST_NAME=""
GIT_REF="dev"
SERVICE_NAME="dev-tailmox"
ROOT_PASSWORD=""
TIMEOUT="300"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)
      [[ $# -ge 2 ]] || die "--vmid requires a value"
      VMID="$2"
      shift 2
      ;;
    --hostname)
      [[ $# -ge 2 ]] || die "--hostname requires a value"
      HOST_NAME="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || die "--ref requires a value"
      GIT_REF="$2"
      shift 2
      ;;
    --service-name)
      [[ $# -ge 2 ]] || die "--service-name requires a value"
      SERVICE_NAME="$2"
      shift 2
      ;;
    --root-password)
      [[ $# -ge 2 ]] || die "--root-password requires a value"
      ROOT_PASSWORD="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      TIMEOUT="$2"
      shift 2
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

require_command qm

[[ "$VMID" =~ ^[1-9][0-9]*$ ]] || die "--vmid must be a positive integer"
[[ -n "$HOST_NAME" ]] || HOST_NAME="tailmox${VMID}"
[[ "$HOST_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
  die "--hostname must be a lowercase DNS label"
[[ "$GIT_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$GIT_REF" != *..* ]] ||
  die "--ref contains unsupported characters"
[[ "$SERVICE_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
  die "--service-name must be a lowercase DNS label"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
if [[ -n "$ROOT_PASSWORD" && ! "$ROOT_PASSWORD" =~ ^[A-Za-z0-9]{12,24}$ ]]; then
  die "--root-password must be 12-24 alphanumeric characters"
fi

qm status "$VMID" >/dev/null 2>&1 || die "VM ID $VMID does not exist"

read -r -d '' remote_script <<'EOF' || true
set -Eeuo pipefail
HOST_NAME=$1
GIT_REF=$2
SERVICE_NAME=$3
ROOT_PASSWORD=$4
ETC_DIR=/etc
INTERFACES_FILE="$ETC_DIR/network/interfaces"
HOSTS_FILE="$ETC_DIR/hosts"
HOSTNAME_FILE="$ETC_DIR/hostname"
ENVIRONMENT_FILE="$ETC_DIR/environment"
PROFILE_DIR="$ETC_DIR/profile.d"
DHCLIENT_PATH=/sbin/dhclient

[[ -f "$INTERFACES_FILE" && -f "$HOSTS_FILE" ]] ||
  { printf 'Missing guest network or hosts configuration.\n' >&2; exit 1; }

if [[ ! -x "$DHCLIENT_PATH" ]]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y isc-dhcp-client
fi
[[ -x "$DHCLIENT_PATH" ]] ||
  { printf 'DHCP client was not installed.\n' >&2; exit 1; }

cat >"$INTERFACES_FILE" <<'NETWORK_EOF'
auto lo
iface lo inet loopback

iface ens18 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports ens18
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
NETWORK_EOF

OLD_HOST_NAME=$(hostname)
HOSTS_TEMP=$(mktemp "$HOSTS_FILE.XXXXXX")
awk -v old="$OLD_HOST_NAME" -v new="$HOST_NAME" '
  {
    remove = 0
    for (field = 2; field <= NF; field++) {
      short = $field
      sub(/\.local$/, "", short)
      if (short == "tailmox-image" || short == old || short == new) remove = 1
    }
    if (!remove) print
  }
' "$HOSTS_FILE" >"$HOSTS_TEMP"
printf '127.0.1.1 %s.local %s\n' "$HOST_NAME" "$HOST_NAME" >>"$HOSTS_TEMP"
install -m 0644 "$HOSTS_TEMP" "$HOSTS_FILE"
rm -f "$HOSTS_TEMP"
printf '%s\n' "$HOST_NAME" >"$HOSTNAME_FILE"
hostnamectl set-hostname "$HOST_NAME"

if [[ -n "$ROOT_PASSWORD" ]]; then
  printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
fi

mkdir -p "$PROFILE_DIR"
ENV_TEMP=$(mktemp "$ENVIRONMENT_FILE.XXXXXX")
if [[ -f "$ENVIRONMENT_FILE" ]]; then
  grep -v '^TAILMOX_TAILSCALE_SERVICE_NAME=' "$ENVIRONMENT_FILE" >"$ENV_TEMP" || true
fi
printf 'TAILMOX_TAILSCALE_SERVICE_NAME=%s\n' "$SERVICE_NAME" >>"$ENV_TEMP"
install -m 0644 "$ENV_TEMP" "$ENVIRONMENT_FILE"
rm -f "$ENV_TEMP"
printf 'export TAILMOX_TAILSCALE_SERVICE_NAME=%q\n' "$SERVICE_NAME" >"$PROFILE_DIR/tailmox-dev-service.sh"

if [[ -d /opt/tailmox/.git ]]; then
  git -C /opt/tailmox fetch --prune origin "$GIT_REF"
  git -C /opt/tailmox switch --detach --quiet FETCH_HEAD
else
  git clone --branch "$GIT_REF" --single-branch https://github.com/willjasen/tailmox.git /opt/tailmox
fi

printf 'Guest preparation complete: %s\n' "$HOST_NAME"
EOF

printf 'Preparing VM %s as %s through the guest agent...\n' "$VMID" "$HOST_NAME"
qm guest exec "$VMID" --timeout "$TIMEOUT" -- \
  bash -lc "$remote_script" -- "$HOST_NAME" "$GIT_REF" "$SERVICE_NAME" "$ROOT_PASSWORD"
printf 'Reboot VM %s before running Tailmox.\n' "$VMID"
