#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
export TEST_STATE_DIR

curl() {
  local arguments="$*"

  case "$arguments" in
    *"/cluster/resources?type=vm"*)
      if [[ "${MOCK_EXISTING_VM:-false}" == true ]]; then
        printf '%s\n' \
          '{"data":[{"type":"qemu","template":1,"vmid":100,"name":"tailmox-template","node":"pve4"},{"type":"qemu","template":0,"vmid":150,"name":"tailmox2","node":"pve4"}]}'
      else
        printf '%s\n' \
          '{"data":[{"type":"qemu","template":1,"vmid":100,"name":"tailmox-template","node":"pve4"}]}'
      fi
      ;;
    *"/cluster/nextid"*)
      printf '%s\n' '{"data":"200"}'
      ;;
    *"/nodes/pve4/storage"*)
      printf '%s\n' \
        '{"data":[{"storage":"local-zfs","active":1,"content":"images,rootdir"}]}'
      ;;
    *"/nodes/pve4/network"*)
      printf '%s\n' \
        '{"data":[{"iface":"vmbr0","type":"bridge"}]}'
      ;;
    *"/clone"*)
      printf '%s\n' "$arguments" >>"$TEST_STATE_DIR/clone-calls"
      printf '%s\n' '{"data":"UPID:pve4:clone"}'
      ;;
    *"/config"*)
      printf '%s\n' "$arguments" >>"$TEST_STATE_DIR/config-calls"
      printf '%s\n' '{"data":null}'
      ;;
    *"/status/start"*)
      printf '%s\n' "$arguments" >>"$TEST_STATE_DIR/start-calls"
      printf '%s\n' '{"data":"UPID:pve4:start"}'
      ;;
    *"/tasks/"*"/status"*)
      printf '%s\n' '{"data":{"status":"stopped","exitstatus":"OK"}}'
      ;;
    *"/nodes")
      printf '%s\n' '{"data":[{"node":"pve4","status":"online"}]}'
      ;;
    *)
      printf 'Unexpected curl call: %s\n' "$arguments" >&2
      return 1
      ;;
  esac
}
export -f curl

OUTPUT=$(
  PVE_API_TOKEN_ID='root@pam!tailmox' \
  PVE_API_TOKEN_SECRET='test-secret' \
    "$TEST_ROOT/test-env/deploy-vms-api.sh" \
      --api-url https://pve4.example.ts.net \
      --node pve4 \
      --storage local-zfs \
      --bridge vmbr0 \
      --count 2 \
      --start
)

[[ "$(grep -c '/clone' "$TEST_STATE_DIR/clone-calls")" -eq 2 ]] ||
  { echo "FAIL: expected two clone calls" >&2; exit 1; }
[[ "$(grep -c '/config' "$TEST_STATE_DIR/config-calls")" -eq 2 ]] ||
  { echo "FAIL: expected two network configuration calls" >&2; exit 1; }
[[ "$(grep -c '/status/start' "$TEST_STATE_DIR/start-calls")" -eq 2 ]] ||
  { echo "FAIL: expected two start calls" >&2; exit 1; }
grep -q 'Created 2 VM(s) successfully.' <<<"$OUTPUT" ||
  { echo "FAIL: success summary was not emitted" >&2; exit 1; }

echo "PASS: API deployment validates resources, clones, configures, and starts VMs"

: >"$TEST_STATE_DIR/clone-calls"
if MOCK_EXISTING_VM=true \
  PVE_API_TOKEN_ID='root@pam!tailmox' \
  PVE_API_TOKEN_SECRET='test-secret' \
    "$TEST_ROOT/test-env/deploy-vms-api.sh" \
      --api-url https://pve4.example.ts.net \
      --node pve4 \
      --count 3 >/dev/null 2>&1; then
  echo "FAIL: an existing planned VM name did not stop deployment" >&2
  exit 1
fi

[[ ! -s "$TEST_STATE_DIR/clone-calls" ]] ||
  { echo "FAIL: deployment wrote to Proxmox before validating all VM names" >&2; exit 1; }

echo "PASS: API deployment validates every planned VM name before cloning"
