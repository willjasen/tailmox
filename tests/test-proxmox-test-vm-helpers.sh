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
chmod +x "$TEST_STATE_DIR/bin/"*

PATH="$TEST_STATE_DIR/bin:$PATH" \
  "$TEST_ROOT/test-env/configure-proxmox-test-vm.sh" --vmid 50051 --start
grep -Fq -- 'set 50051 --serial0 socket --vga std --agent 1 --net0 virtio,bridge=vlan3' \
  "$TEST_STATE_DIR/qm-calls" ||
  { printf 'FAIL: host helper did not configure VM hardware\n' >&2; exit 1; }
grep -Fqx 'start 50051' "$TEST_STATE_DIR/qm-calls" ||
  { printf 'FAIL: host helper did not start the requested VM\n' >&2; exit 1; }

PATH="$TEST_STATE_DIR/bin:$PATH" \
  "$TEST_ROOT/test-env/prepare-proxmox-test-guest.sh"
grep -Fqx 'update' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not update package metadata\n' >&2; exit 1; }
grep -Fq -- 'install -y qemu-guest-agent git jq expect' "$TEST_STATE_DIR/apt-calls" ||
  { printf 'FAIL: guest helper did not install required packages\n' >&2; exit 1; }
grep -Fqx 'enable --now qemu-guest-agent.service' "$TEST_STATE_DIR/systemctl-calls" ||
  { printf 'FAIL: guest helper did not enable qemu-guest-agent\n' >&2; exit 1; }
grep -Fqx 'enable --now serial-getty@ttyS0.service' "$TEST_STATE_DIR/systemctl-calls" ||
  { printf 'FAIL: guest helper did not enable serial-getty\n' >&2; exit 1; }

printf 'PASS: Proxmox test VM helpers configure hardware and guest dependencies\n'
