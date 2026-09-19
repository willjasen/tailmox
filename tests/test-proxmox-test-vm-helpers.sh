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
chmod +x "$TEST_STATE_DIR/bin/"*

PATH="$TEST_STATE_DIR/bin:$PATH" \
  "$TEST_ROOT/test-env/configure-proxmox-test-vm.sh" --vmid 50051 --start
grep -Fq -- 'set 50051 --serial0 socket --vga std --agent 1 --net0 virtio,bridge=vlan3' \
  "$TEST_STATE_DIR/qm-calls" ||
  { printf 'FAIL: host helper did not configure VM hardware\n' >&2; exit 1; }
grep -Fqx 'start 50051' "$TEST_STATE_DIR/qm-calls" ||
  { printf 'FAIL: host helper did not start the requested VM\n' >&2; exit 1; }

mkdir -p "$TEST_STATE_DIR/etc"
PATH="$TEST_STATE_DIR/bin:$PATH" \
  PATH="$TEST_STATE_DIR/bin:/usr/bin:/bin" \
  TAILMOX_ETC_DIR="$TEST_STATE_DIR/etc" \
  "$TEST_ROOT/test-env/prepare-proxmox-test-guest.sh"
grep -Fqx 'update' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not update package metadata\n' >&2; exit 1; }
grep -Fq -- 'install -y ca-certificates curl isc-dhcp-client resolvconf qemu-guest-agent git jq expect' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not install required packages\n' >&2; exit 1; }
grep -Fq 'https://tailscale.com/install.sh' "$TEST_STATE_DIR/curl-calls" ||
  { printf 'FAIL: guest helper did not install Tailscale\n' >&2; exit 1; }
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
[[ -L "$TEST_STATE_DIR/etc/resolv.conf" ]] ||
  { printf 'FAIL: guest helper did not delegate DNS to resolvconf\n' >&2; exit 1; }

printf 'PASS: Proxmox test VM helpers configure hardware and guest dependencies\n'
