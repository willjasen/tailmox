#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
export TEST_STATE_DIR

printf 'password\n' >"$TEST_STATE_DIR/password"
printf 'iso\n' >"$TEST_STATE_DIR/source.iso"

id() { [[ "${1:-}" == "-u" ]] && echo 0; }
curl() { cp "$TEST_STATE_DIR/source.iso" "$TEST_STATE_DIR/downloaded.iso"; }
sha256sum() { [[ "${1:-}" == "--check" ]]; }
openssl() {
  if [[ "${1:-}" == "rand" ]]; then
    echo abcd
  else
    echo '$6$test$hash'
  fi
}
ip() { [[ "$*" == "link show vlan3" ]]; }
pvesh() {
  [[ "$*" == "get /cluster/nextid" ]] && { echo 50051; return; }
  [[ "$*" == "get /cluster/resources --type vm --output-format json" ]] && { echo '[]'; return; }
  return 1
}
pvesm() {
  if [[ "${1:-}" == "status" ]]; then
    printf '%s\n' "Name Type Status" "local-zfs zfspool active"
  else
    mkdir -p "$TEST_STATE_DIR/iso-target"
    printf '%s\n' "$TEST_STATE_DIR/iso-target"
  fi
}
qm() {
  printf '%s\n' "$*" >>"$TEST_STATE_DIR/qm-calls"
  [[ "${1:-}" != "status" ]]
}
proxmox-auto-install-assistant() {
  local output=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--output" ]] && output="$2"
    shift
  done
  cp "$TEST_STATE_DIR/source.iso" "$output"
}
export -f id curl sha256sum openssl ip pvesh pvesm qm proxmox-auto-install-assistant

OUTPUT=$(
  PATH="$TEST_ROOT/tests:$PATH" \
  "$TEST_ROOT/test-env/install-proxmox-test-vm.sh" \
    --iso-url https://example.invalid/proxmox-ve.iso \
    --iso-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    --root-password-file "$TEST_STATE_DIR/password" \
    --storage local-zfs \
    --iso-storage local \
    --vmid 50051 \
    --work-dir "$TEST_STATE_DIR/work" 2>&1
)

grep -q '^create 50051 ' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: installer VM was not created" >&2; exit 1; }
grep -q -- '--serial0 socket' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: serial console was not configured" >&2; exit 1; }
grep -q -- '--agent 1' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: guest agent was not configured" >&2; exit 1; }
grep -q 'curl -fsSL https://tailscale.com/install.sh | sh' \
  "$TEST_STATE_DIR/work/tailmox-first-boot.sh" ||
  { echo "FAIL: first-boot hook does not install Tailscale" >&2; exit 1; }
grep -q 'systemctl enable --now qemu-guest-agent.service serial-getty@ttyS0.service' \
  "$TEST_STATE_DIR/work/tailmox-first-boot.sh" ||
  { echo "FAIL: first-boot hook does not enable guest agent and ttyS0" >&2; exit 1; }
grep -q 'systemctl enable --now tailscaled.service' \
  "$TEST_STATE_DIR/work/tailmox-first-boot.sh" ||
  { echo "FAIL: first-boot hook does not enable Tailscale" >&2; exit 1; }
grep -q 'pve-enterprise.sources' "$TEST_STATE_DIR/work/tailmox-first-boot.sh" &&
  grep -q 'pve-no-subscription.list' "$TEST_STATE_DIR/work/tailmox-first-boot.sh" ||
  { echo "FAIL: first-boot hook does not configure Proxmox repositories" >&2; exit 1; }
grep -q 'unattended installer media' <<<"$OUTPUT" ||
  { echo "FAIL: installer summary was not emitted" >&2; exit 1; }

echo "PASS: ISO installer prepares and creates a guest-agent-enabled VM"
