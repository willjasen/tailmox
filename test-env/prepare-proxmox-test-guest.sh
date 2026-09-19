#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES=(qemu-guest-agent git jq expect)

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_command apt-get
require_command systemctl

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this script as root"
fi

printf 'Refreshing package metadata...\n'
apt-get update
printf 'Installing Tailmox test dependencies...\n'
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

systemctl enable --now qemu-guest-agent.service
systemctl enable --now serial-getty@ttyS0.service

printf 'Nested Proxmox guest preparation completed.\n'
printf 'Enabled services: qemu-guest-agent.service, serial-getty@ttyS0.service\n'
