#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
export TEST_STATE_DIR

touch "$TEST_STATE_DIR/tailmox.qcow2"

id() {
  if [[ "${1:-}" == "-u" ]]; then
    echo 0
    return 0
  fi
  return 1
}

pvesm() {
  if [[ "${1:-}" == "status" ]]; then
    printf '%s\n' \
      "Name       Type     Status" \
      "local-zfs  zfspool  active"
    return 0
  fi
  return 1
}

pvesh() {
  if [[ "$*" == "get /cluster/resources --type vm --output-format json" ]]; then
    echo '[]'
    return 0
  fi

  if [[ "$*" == "get /cluster/nextid" ]]; then
    local current=99
    if [[ -f "$TEST_STATE_DIR/next-id" ]]; then
      current=$(<"$TEST_STATE_DIR/next-id")
    fi
    current=$((current + 1))
    printf '%s\n' "$current" >"$TEST_STATE_DIR/next-id"
    printf '%s\n' "$current"
    return 0
  fi

  return 1
}

ip() {
  [[ "${1:-}" == "link" && "${2:-}" == "show" ]]
}

qm() {
  printf '%s\n' "$*" >>"$TEST_STATE_DIR/qm-calls"

  case "${1:-}" in
    status)
      return 1
      ;;
    config)
      echo 'unused0: local-zfs:vm-100-disk-0'
      ;;
    *)
      return 0
      ;;
  esac
}

export -f id pvesm pvesh ip qm

OUTPUT=$(
  "$TEST_ROOT/test-env/create-vm-template.sh" \
    --template "$TEST_STATE_DIR/tailmox.qcow2" \
    --storage local-zfs \
    --bridge vmbr0 \
    --clone-count 2
)

grep -q '^create 100 ' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: template VM was not created" >&2; exit 1; }
grep -q '^importdisk 100 .* local-zfs$' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: disk was not imported into the selected storage" >&2; exit 1; }
grep -q '^set 100 --scsi0 local-zfs:vm-100-disk-0$' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: imported disk was not discovered and attached" >&2; exit 1; }
[[ "$(grep -c '^clone 100 ' "$TEST_STATE_DIR/qm-calls")" -eq 2 ]] ||
  { echo "FAIL: expected two linked clones" >&2; exit 1; }
grep -q 'Template and linked-clone deployment completed successfully.' <<<"$OUTPUT" ||
  { echo "FAIL: success summary was not emitted" >&2; exit 1; }

echo "PASS: local deployment validates resources, imports a disk, and creates clones"
