#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
mkdir -p "$TEST_STATE_DIR/bin"
export TEST_STATE_DIR

id() {
  if [[ "$1" == "-u" ]]; then
    printf '0\n'
  else
    command id "$@"
  fi
}
export -f id

cat >"$TEST_STATE_DIR/bin/qm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/qm-calls"
case "$1" in
  status) exit 0 ;;
  set|start) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat >"$TEST_STATE_DIR/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/apt-calls"
EOF
cat >"$TEST_STATE_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/systemctl-calls"
EOF
cat >"$TEST_STATE_DIR/bin/resolvconf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/resolvconf-calls"
EOF
cat >"$TEST_STATE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/curl-calls"
cat >/dev/null
EOF
cat >"$TEST_STATE_DIR/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/tailscale-calls"
EOF
cat >"$TEST_STATE_DIR/bin/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/hostnamectl-calls"
EOF
chmod +x "$TEST_STATE_DIR/bin/"*

PATH="$TEST_STATE_DIR/bin:$PATH" \
  "$TEST_ROOT/test-env/configure-proxmox-test-vm.sh" --vmid 50051 --start
grep -Fq -- 'set 50051 --serial0 socket --vga std --agent 1 --net0 virtio,bridge=vlan3' \
  "$TEST_STATE_DIR/qm-calls" ||
  { printf 'FAIL: host helper did not configure VM hardware\n' >&2; exit 1; }
grep -Fqx 'start 50051' "$TEST_STATE_DIR/qm-calls" ||
  { printf 'FAIL: host helper did not start the requested VM\n' >&2; exit 1; }

mkdir -p "$TEST_STATE_DIR/etc/apt/sources.list.d"
: >"$TEST_STATE_DIR/etc/hosts"
# Proxmox 9's DEB822 .sources format uses a boolean "Enabled: true/false"
# key, not the legacy "yes"/"no" used by one-line .list files.
cat >"$TEST_STATE_DIR/etc/apt/sources.list.d/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Enabled: true
EOF
# Proxmox ships the enterprise ceph repo under its own file name (not
# pve-enterprise.*), which previously was not disabled. It also may omit
# the Enabled key entirely, which defaults to enabled.
cat >"$TEST_STATE_DIR/etc/apt/sources.list.d/ceph.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
EOF
PATH="$TEST_STATE_DIR/bin:$PATH" \
  PATH="$TEST_STATE_DIR/bin:/usr/bin:/bin" \
  TAILMOX_ETC_DIR="$TEST_STATE_DIR/etc" \
  TAILMOX_IMAGE_HOSTNAME=tailmox-iabcd \
  "$TEST_ROOT/test-env/prepare-proxmox-test-guest.sh"
grep -Fqx 'update' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not update package metadata\n' >&2; exit 1; }
grep -Fqx 'Enabled: false' "$TEST_STATE_DIR/etc/apt/sources.list.d/pve-enterprise.sources" ||
  { printf 'FAIL: guest helper did not disable the pve enterprise repository\n' >&2; exit 1; }
grep -Fqx 'Enabled: false' "$TEST_STATE_DIR/etc/apt/sources.list.d/ceph.sources" ||
  { printf 'FAIL: guest helper did not disable the ceph enterprise repository\n' >&2; exit 1; }
grep -Fq 'pve-no-subscription' "$TEST_STATE_DIR/etc/apt/sources.list.d/pve-no-subscription.list" ||
  { printf 'FAIL: guest helper did not enable the no-subscription repository\n' >&2; exit 1; }
grep -Fq -- 'install -y ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not install required packages\n' >&2; exit 1; }
grep -Fqx 'update --yes' "$TEST_STATE_DIR/tailscale-calls" ||
  { printf 'FAIL: guest helper did not update installed Tailscale\n' >&2; exit 1; }
grep -Fq -- 'install -y --only-upgrade ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not update installed dependencies\n' >&2; exit 1; }
grep -Fqx 'enable --now qemu-guest-agent.service' "$TEST_STATE_DIR/systemctl-calls" ||
  { printf 'FAIL: guest helper did not enable qemu-guest-agent\n' >&2; exit 1; }
grep -Fqx 'enable --now serial-getty@ttyS0.service' "$TEST_STATE_DIR/systemctl-calls" ||
  { printf 'FAIL: guest helper did not enable serial-getty\n' >&2; exit 1; }
grep -Fqx 'restart networking.service' "$TEST_STATE_DIR/systemctl-calls" ||
  { printf 'FAIL: guest helper did not restart DHCP networking\n' >&2; exit 1; }
grep -Fqx 'enable --now resolvconf.service' "$TEST_STATE_DIR/systemctl-calls" ||
  { printf 'FAIL: guest helper did not enable DHCP DNS management\n' >&2; exit 1; }
grep -Fqx -- '-u' "$TEST_STATE_DIR/resolvconf-calls" ||
  { printf 'FAIL: guest helper did not refresh DHCP-provided DNS\n' >&2; exit 1; }
grep -Fq 'iface vmbr0 inet dhcp' "$TEST_STATE_DIR/etc/network/interfaces" ||
  { printf 'FAIL: guest helper did not configure DHCP on vmbr0\n' >&2; exit 1; }
grep -Fqx 'set-hostname tailmox-iabcd' "$TEST_STATE_DIR/hostnamectl-calls" ||
  { printf 'FAIL: guest helper did not set the generated image hostname\n' >&2; exit 1; }
[[ -L "$TEST_STATE_DIR/etc/resolv.conf" ]] ||
  { printf 'FAIL: guest helper did not delegate DNS to resolvconf\n' >&2; exit 1; }

printf 'PASS: Proxmox test VM helpers configure hardware and guest dependencies\n'
