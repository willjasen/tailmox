#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<EOF
Usage: $0 --hostname NAME [OPTIONS]

Prepare a newly booted linked clone of the Tailmox Proxmox test image.

Options:
  --hostname NAME       Unique guest hostname (required)
  --ref REF             Git branch or ref to deploy (default: dev)
  --repo URL            Git repository URL (default: Tailmox GitHub repository)
  --service-name NAME   Shared Tailscale service label (default: dev-tailmox)
  --root-password PASS  Alphanumeric root password (default: generate one)
  --help                Show this help

The script installs the DHCP client, changes the guest network to DHCP,
normalizes the hostname files, and deploys the requested Tailmox revision.
Reboot the guest after it completes so the new network configuration is used.
It does not authenticate Tailscale or create/join a Proxmox cluster.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

HOST_NAME=""
GIT_REF="dev"
REPO_URL="https://github.com/willjasen/tailmox.git"
SERVICE_NAME="dev-tailmox"
ROOT_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      REPO_URL="$2"
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root inside the linked clone"
[[ "$HOST_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
  die "--hostname must be a lowercase DNS label"
[[ "$GIT_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$GIT_REF" != *..* ]] ||
  die "--ref contains unsupported characters"
[[ "$SERVICE_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
  die "--service-name must be a lowercase DNS label"
[[ -n "$REPO_URL" ]] || die "--repo cannot be empty"
if [[ -n "$ROOT_PASSWORD" && ! "$ROOT_PASSWORD" =~ ^[A-Za-z0-9]{12,24}$ ]]; then
  die "--root-password must be 12-24 alphanumeric characters"
fi
if [[ -z "$ROOT_PASSWORD" ]]; then
  require_command openssl
  ROOT_PASSWORD=$(openssl rand -hex 8)
fi

ETC_DIR="${TAILMOX_ETC_DIR:-/etc}"
INSTALL_DIR="${TAILMOX_INSTALL_DIR:-/opt/tailmox}"
BIN_DIR="${TAILMOX_BIN_DIR:-/usr/local/bin}"
DHCLIENT_PATH="${TAILMOX_DHCLIENT_PATH:-/sbin/dhclient}"
INTERFACES_FILE="$ETC_DIR/network/interfaces"
HOSTS_FILE="$ETC_DIR/hosts"
HOSTNAME_FILE="$ETC_DIR/hostname"
ENVIRONMENT_FILE="$ETC_DIR/environment"
PROFILE_DIR="$ETC_DIR/profile.d"
PROFILE_FILE="$PROFILE_DIR/tailmox-dev-service.sh"

require_command apt-get
require_command git
require_command hostname
require_command hostnamectl
require_command install
require_command awk
require_command chpasswd

[[ -f "$INTERFACES_FILE" ]] || die "Missing network configuration: $INTERFACES_FILE"
[[ -f "$HOSTS_FILE" ]] || die "Missing hosts file: $HOSTS_FILE"

if ! grep -Fq '192.168.123.90' "$INTERFACES_FILE" &&
   ! { grep -Fq 'iface vmbr0 inet dhcp' "$INTERFACES_FILE" &&
       grep -Fq 'bridge-ports ens18' "$INTERFACES_FILE"; }; then
  die "Refusing to replace an unrecognized network configuration"
fi

if [[ ! -x "$DHCLIENT_PATH" ]]; then
  printf 'Installing the DHCP client...\n'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y isc-dhcp-client
  [[ -x "$DHCLIENT_PATH" ]] || die "DHCP client installation did not create $DHCLIENT_PATH"
fi

if [[ ! -e "$INTERFACES_FILE.pre-tailmox" ]]; then
  install -m 0644 "$INTERFACES_FILE" "$INTERFACES_FILE.pre-tailmox"
fi
cat >"$INTERFACES_FILE" <<'EOF'
auto lo
iface lo inet loopback

iface ens18 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports ens18
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
EOF

OLD_HOST_NAME=$(hostname)
HOSTS_TEMP=$(mktemp "$HOSTS_FILE.XXXXXX")
awk -v old="$OLD_HOST_NAME" -v new="$HOST_NAME" '
  {
    remove = 0
    for (field = 2; field <= NF; field++) {
      short = $field
      sub(/\.local$/, "", short)
      if (short == "tailmox-image" || short == old || short == new) {
        remove = 1
      }
    }
    if (!remove) print
  }
' "$HOSTS_FILE" >"$HOSTS_TEMP"
printf '127.0.1.1 %s.local %s\n' "$HOST_NAME" "$HOST_NAME" >>"$HOSTS_TEMP"
install -m 0644 "$HOSTS_TEMP" "$HOSTS_FILE"
rm -f "$HOSTS_TEMP"
printf '%s\n' "$HOST_NAME" >"$HOSTNAME_FILE"
hostnamectl set-hostname "$HOST_NAME"

printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd

mkdir -p "$PROFILE_DIR"
ENV_TEMP=$(mktemp "$ENVIRONMENT_FILE.XXXXXX")
if [[ -f "$ENVIRONMENT_FILE" ]]; then
  grep -v '^TAILMOX_TAILSCALE_SERVICE_NAME=' "$ENVIRONMENT_FILE" >"$ENV_TEMP" || true
fi
printf 'TAILMOX_TAILSCALE_SERVICE_NAME=%s\n' "$SERVICE_NAME" >>"$ENV_TEMP"
install -m 0644 "$ENV_TEMP" "$ENVIRONMENT_FILE"
rm -f "$ENV_TEMP"
printf 'export TAILMOX_TAILSCALE_SERVICE_NAME=%q\n' "$SERVICE_NAME" >"$PROFILE_FILE"
chmod 0644 "$PROFILE_FILE"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  [[ -z "$(git -C "$INSTALL_DIR" status --porcelain)" ]] ||
    die "Refusing to update a dirty checkout at $INSTALL_DIR"
  CURRENT_ORIGIN=$(git -C "$INSTALL_DIR" remote get-url origin)
  [[ "$CURRENT_ORIGIN" == "$REPO_URL" || "${CURRENT_ORIGIN%.git}" == "${REPO_URL%.git}" ]] ||
    die "Existing checkout origin does not match --repo"
  git -C "$INSTALL_DIR" fetch --prune origin "$GIT_REF"
  if git -C "$INSTALL_DIR" show-ref --verify --quiet "refs/heads/$GIT_REF"; then
    git -C "$INSTALL_DIR" switch "$GIT_REF"
  else
    git -C "$INSTALL_DIR" switch --create "$GIT_REF" --track "origin/$GIT_REF"
  fi
  git -C "$INSTALL_DIR" merge --ff-only "origin/$GIT_REF"
elif [[ -e "$INSTALL_DIR" ]]; then
  die "Refusing to replace non-Git path: $INSTALL_DIR"
else
  git clone --branch "$GIT_REF" --single-branch "$REPO_URL" "$INSTALL_DIR"
fi

TAILMOX_BIN_DIR="$BIN_DIR" "$INSTALL_DIR/tailmox" help >/dev/null

printf '\nLinked clone preparation complete.\n'
printf '  Hostname: %s\n' "$HOST_NAME"
printf '  Network: DHCP on guest bridge vmbr0 (Proxmox NIC should use vlan3)\n'
printf '  Tailmox: %s at %s\n' "$GIT_REF" "$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
printf '  Service label: %s\n' "$SERVICE_NAME"
printf '  Root password: %s\n' "$ROOT_PASSWORD"
printf 'Reboot this guest before using it.\n'
