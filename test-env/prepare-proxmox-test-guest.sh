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
require_command mkdir
require_command ln
require_command rm

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this script as root"
fi

printf 'Refreshing package metadata...\n'
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

printf 'Nested Proxmox guest preparation completed.\n'
printf 'Enabled services: qemu-guest-agent.service, serial-getty@ttyS0.service, resolvconf.service\n'
