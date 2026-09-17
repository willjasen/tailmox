#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT

mkdir -p "$TEST_STATE_DIR/etc/network" "$TEST_STATE_DIR/etc/profile.d" \
  "$TEST_STATE_DIR/opt/tailmox/.git" "$TEST_STATE_DIR/bin" "$TEST_STATE_DIR/usr-bin"
cat >"$TEST_STATE_DIR/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
auto vmbr0
iface vmbr0 inet static
    address 192.168.123.90/24
    gateway 192.168.123.1
    bridge-ports ens18
EOF
cat >"$TEST_STATE_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
192.168.123.90 tailmox-image.local tailmox-image
EOF
printf 'tailmox-image\n' >"$TEST_STATE_DIR/etc/hostname"
printf 'EXISTING=value\nTAILMOX_TAILSCALE_SERVICE_NAME=old-name\n' >"$TEST_STATE_DIR/etc/environment"
touch "$TEST_STATE_DIR/dhclient"
chmod +x "$TEST_STATE_DIR/dhclient"

id() { [[ "${1:-}" == -u ]] && printf '0\n'; }
hostname() { printf 'tailmox-image\n'; }
hostnamectl() { printf '%s\n' "$*" >>"$TEST_STATE_DIR/hostnamectl-calls"; }
apt-get() { printf '%s\n' "$*" >>"$TEST_STATE_DIR/apt-calls"; }
chpasswd() { cat >/dev/null; touch "$TEST_STATE_DIR/password-updated"; }
git() {
  printf '%s\n' "$*" >>"$TEST_STATE_DIR/git-calls"
  case "$*" in
    *'status --porcelain') return 0 ;;
    *'remote get-url origin') printf 'https://github.com/willjasen/tailmox\n' ;;
    *'show-ref --verify --quiet refs/heads/dev') return 0 ;;
    *'rev-parse --short HEAD') printf 'abcdef0\n' ;;
  esac
}
export -f id hostname hostnamectl apt-get chpasswd git
export TEST_STATE_DIR

cat >"$TEST_STATE_DIR/opt/tailmox/tailmox" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$TAILMOX_BIN_DIR"
ln -sfn "$0" "$TAILMOX_BIN_DIR/tailmox"
EOF
chmod +x "$TEST_STATE_DIR/opt/tailmox/tailmox"

TAILMOX_ETC_DIR="$TEST_STATE_DIR/etc" \
TAILMOX_INSTALL_DIR="$TEST_STATE_DIR/opt/tailmox" \
TAILMOX_BIN_DIR="$TEST_STATE_DIR/usr-bin" \
TAILMOX_DHCLIENT_PATH="$TEST_STATE_DIR/dhclient" \
  "$TEST_ROOT/test-env/prepare-linked-clone.sh" --hostname tailmox4 >/dev/null

grep -Fq 'iface vmbr0 inet dhcp' "$TEST_STATE_DIR/etc/network/interfaces" ||
  { printf 'FAIL: DHCP network configuration was not written\n' >&2; exit 1; }
grep -Fq 'bridge-ports ens18' "$TEST_STATE_DIR/etc/network/interfaces" ||
  { printf 'FAIL: expected guest bridge port was not retained\n' >&2; exit 1; }
grep -Fqx '127.0.1.1 tailmox4.local tailmox4' "$TEST_STATE_DIR/etc/hosts" ||
  { printf 'FAIL: hostname entry was not normalized\n' >&2; exit 1; }
if grep -Fq '192.168.123.90' "$TEST_STATE_DIR/etc/hosts"; then
  printf 'FAIL: stale image address remains in hosts file\n' >&2
  exit 1
fi
grep -Fqx 'TAILMOX_TAILSCALE_SERVICE_NAME=dev-tailmox' "$TEST_STATE_DIR/etc/environment" ||
  { printf 'FAIL: development service label was not persisted\n' >&2; exit 1; }
grep -Fq -- '-C '"$TEST_STATE_DIR/opt/tailmox"' fetch --prune origin dev' \
  "$TEST_STATE_DIR/git-calls" ||
  { printf 'FAIL: latest dev revision was not fetched\n' >&2; exit 1; }
grep -Fq -- '-C '"$TEST_STATE_DIR/opt/tailmox"' merge --ff-only origin/dev' \
  "$TEST_STATE_DIR/git-calls" ||
  { printf 'FAIL: checkout was not updated with a fast-forward-only merge\n' >&2; exit 1; }
[[ -L "$TEST_STATE_DIR/usr-bin/tailmox" ]] ||
  { printf 'FAIL: tailmox command was not initialized\n' >&2; exit 1; }
[[ -e "$TEST_STATE_DIR/password-updated" ]] ||
  { printf 'FAIL: root password was not updated\n' >&2; exit 1; }
[[ ! -e "$TEST_STATE_DIR/apt-calls" ]] ||
  { printf 'FAIL: DHCP client was reinstalled unnecessarily\n' >&2; exit 1; }

printf 'PASS: linked clone preparation is safe, repeatable, and deploys dev\n'
