#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT

mkdir -p "$TEST_STATE_DIR/bin"

cat >"$TEST_STATE_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/ssh-calls"
if [[ "$*" == *"mktemp -d /tmp/tailmox-vm-image.XXXXXX"* ]]; then
  printf '/tmp/tailmox-vm-image.test123\n'
fi
EOF

cat >"$TEST_STATE_DIR/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE_DIR/scp-calls"
EOF

chmod +x "$TEST_STATE_DIR/bin/ssh" "$TEST_STATE_DIR/bin/scp"
export TEST_STATE_DIR

OUTPUT=$(PATH="$TEST_STATE_DIR/bin:$PATH" \
  "$TEST_ROOT/test-env/setup-vm-image.sh" \
  --host pve-a2 --storage local-zfs --clone-count 2)

grep -Fq 'root@pve-a2 mktemp -d /tmp/tailmox-vm-image.XXXXXX' \
  "$TEST_STATE_DIR/ssh-calls" ||
  { printf 'FAIL: helper did not connect to pve-a2 as root\n' >&2; exit 1; }
grep -Fq 'root@pve-a2:/tmp/tailmox-vm-image.test123/' \
  "$TEST_STATE_DIR/scp-calls" ||
  { printf 'FAIL: helper did not stage files in its remote workspace\n' >&2; exit 1; }
grep -Fq 'create-vm-template.sh --storage local-zfs --clone-count 2' \
  "$TEST_STATE_DIR/ssh-calls" ||
  { printf 'FAIL: helper did not forward builder options\n' >&2; exit 1; }
grep -Fq "rm -rf -- '/tmp/tailmox-vm-image.test123'" \
  "$TEST_STATE_DIR/ssh-calls" ||
  { printf 'FAIL: helper did not clean up its remote workspace\n' >&2; exit 1; }
grep -Fq 'Setting up the Tailmox VM image on pve-a2...' <<<"$OUTPUT" ||
  { printf 'FAIL: helper did not report the target host\n' >&2; exit 1; }

if PATH="$TEST_STATE_DIR/bin:$PATH" \
  "$TEST_ROOT/test-env/setup-vm-image.sh" --host 'pve-a2;unsafe' \
  >/dev/null 2>&1; then
  printf 'FAIL: helper accepted an unsafe host value\n' >&2
  exit 1
fi

printf 'PASS: local VM image setup stages and runs the builder safely over SSH\n'
