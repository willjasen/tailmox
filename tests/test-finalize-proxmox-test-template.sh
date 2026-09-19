#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT
export TEST_STATE_DIR

id() { [[ "${1:-}" == "-u" ]] && echo 0; }
printf 'tailmox-test\n' >"$TEST_STATE_DIR/password"
pvesh() {
  [[ "$*" == "get /cluster/resources --type vm --output-format json" ]] && {
    echo '[]'
    return
  }
  return 1
}
qm() {
  printf '%s\n' "$*" >>"$TEST_STATE_DIR/qm-calls"
  case "${1:-}" in
    status)
      if [[ "${2:-}" == "50051" ]]; then
        echo "status: stopped"
        return 0
      fi
      return 1
      ;;
    config)
      printf '%s\n' 'name: tailmox-image'
      ;;
    *)
      return 0
      ;;
  esac
}
openssl() {
  local count=0
  [[ -f "$TEST_STATE_DIR/random-count" ]] && count=$(<"$TEST_STATE_DIR/random-count")
  count=$((count + 1))
  printf '%s\n' "$count" >"$TEST_STATE_DIR/random-count"
  printf '0%03x\n' "$count"
}
expect() {
  cat >"$TEST_STATE_DIR/expect-script"
  return 0
}
export -f id pvesh qm openssl expect

OUTPUT=$(
  "$TEST_ROOT/test-env/finalize-proxmox-test-template.sh" \
    --vmid 50051 \
    --clone-count 2 \
    --clone-vmid-start 50052 \
    --root-password-file "$TEST_STATE_DIR/password" \
    --iso-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
)

grep -q '^template 50051$' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: source VM was not converted to a template" >&2; exit 1; }
grep -q '^set 50051 --cores 2 --memory 2048$' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: template resources were not normalized before conversion" >&2; exit 1; }
grep -q '^clone 50051 50052 ' "$TEST_STATE_DIR/qm-calls" &&
  grep -q '^clone 50051 50053 ' "$TEST_STATE_DIR/qm-calls" ||
  { echo "FAIL: linked clones were not created" >&2; exit 1; }
[[ "$(grep -c '^snapshot ' "$TEST_STATE_DIR/qm-calls")" -eq 2 ]] ||
  { echo "FAIL: linked-clone recovery snapshots were not created" >&2; exit 1; }
grep -q 'and 2 linked clone(s) are ready' <<<"$OUTPUT" ||
  { echo "FAIL: finalization summary was not emitted" >&2; exit 1; }
grep -q 'qemu-guest-agent.service serial-getty@ttyS0.service' "$TEST_STATE_DIR/expect-script" ||
  { echo "FAIL: package check does not enable the guest agent and ttyS0" >&2; exit 1; }
grep -q 'apt-get install -y --only-upgrade' "$TEST_STATE_DIR/expect-script" ||
  { echo "FAIL: package check performs an unrestricted package upgrade" >&2; exit 1; }

echo "PASS: installed VM converts to template with linked clones"
