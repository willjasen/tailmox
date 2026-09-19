#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES=(ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect)
ETC_DIR="${TAILMOX_ETC_DIR:-/etc}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_command apt-get
require_command systemctl
require_command curl
require_command openssl
require_command mkdir
require_command ln
require_command rm

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this script as root"
fi

IMAGE_HOSTNAME="${TAILMOX_IMAGE_HOSTNAME:-tailmox-i$(openssl rand -hex 2)}"
[[ "$IMAGE_HOSTNAME" =~ ^tailmox-i[0-9a-f]{4}$ ]] ||
  die "TAILMOX_IMAGE_HOSTNAME must match tailmox-i####"
hostnamectl set-hostname "$IMAGE_HOSTNAME"
HOSTS_FILE="$ETC_DIR/hosts"
if grep -q '^127\.0\.1\.1[[:space:]]' "$HOSTS_FILE"; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $IMAGE_HOSTNAME.local $IMAGE_HOSTNAME/" "$HOSTS_FILE"
else
  printf '127.0.1.1 %s.local %s\n' "$IMAGE_HOSTNAME" "$IMAGE_HOSTNAME" >>"$HOSTS_FILE"
fi

printf 'Refreshing package metadata...\n'
PROXMOX_CODENAME="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
APT_SOURCES_DIR="$ETC_DIR/apt/sources.list.d"
# Disable every enterprise repository file (for example pve-enterprise.sources
# and ceph.sources), not just a fixed set of filenames, since Proxmox ships
# the enterprise ceph repo under its own file name.
shopt -s nullglob
for source_file in "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources; do
  if grep -q 'enterprise\.proxmox\.com' "$source_file"; then
    case "$source_file" in
      *.sources)
        # DEB822 format uses a boolean "Enabled: true/false" key (not
        # "yes"/"no"), and the key defaults to enabled when absent.
        if grep -q '^Enabled:' "$source_file"; then
          sed -i -E 's/^Enabled:.*/Enabled: false/' "$source_file"
        else
          printf 'Enabled: false\n' >>"$source_file"
        fi
        ;;
      *)
        sed -i -E 's|^deb |# deb |' "$source_file"
        ;;
    esac
  fi
done
shopt -u nullglob
mkdir -p "$APT_SOURCES_DIR"
cat > "$APT_SOURCES_DIR/pve-no-subscription.list" <<EOF
deb http://download.proxmox.com/debian/pve ${PROXMOX_CODENAME} pve-no-subscription
EOF
apt-get update
printf 'Installing Tailmox test dependencies...\n'
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
if ! command -v tailscale >/dev/null 2>&1; then
  printf 'Installing Tailscale...\n'
  curl -fsSL https://tailscale.com/install.sh | sh
else
  printf 'Updating Tailscale...\n'
  tailscale update --yes
fi
printf 'Updating installed Tailmox test dependencies...\n'
DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${PACKAGES[@]}"

printf 'Configuring DHCP networking and DNS...\n'
mkdir -p "$ETC_DIR/network"
cat >"$ETC_DIR/network/interfaces" <<'EOF'
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
rm -f "$ETC_DIR/resolv.conf"
ln -s /run/resolvconf/resolv.conf "$ETC_DIR/resolv.conf"
systemctl restart networking.service

systemctl enable --now qemu-guest-agent.service
systemctl enable --now serial-getty@ttyS0.service
systemctl enable --now resolvconf.service
resolvconf -u

printf 'Nested Proxmox guest preparation completed for image hostname %s.\n' \
  "$IMAGE_HOSTNAME"
printf 'Enabled services: qemu-guest-agent.service, serial-getty@ttyS0.service, resolvconf.service\n'
