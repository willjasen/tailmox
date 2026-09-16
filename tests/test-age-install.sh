#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/archive/age" "$TEST_DIR/bin"
mkdir -p "$TEST_DIR/log"

printf '#!/usr/bin/env bash\nprintf "age test build\\n"\n' > "$TEST_DIR/archive/age/age"
printf '#!/usr/bin/env bash\nprintf "usage: age-keygen -pq\\n"\n' > "$TEST_DIR/archive/age/age-keygen"
chmod +x "$TEST_DIR/archive/age/age" "$TEST_DIR/archive/age/age-keygen"
tar -czf "$TEST_DIR/age.tar.gz" -C "$TEST_DIR/archive" age
CHECKSUM=$(sha256sum "$TEST_DIR/age.tar.gz" | awk '{print $1}')

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_DIR/log"
export TAILMOX_AGE_ARCHITECTURE=amd64
export TAILMOX_AGE_INSTALL_DIR="$TEST_DIR/bin"
export TAILMOX_AGE_VERSION=9.9.9-test
export TAILMOX_AGE_URL="file://$TEST_DIR/age.tar.gz"
export TAILMOX_AGE_SHA256="$CHECKSUM"
source "$ROOT_DIR/tailmox.sh"

install_post_quantum_age >/dev/null
"$TEST_DIR/bin/age-keygen" --help | grep -q -- '-pq'

unset TAILMOX_AGE_VERSION TAILMOX_AGE_URL TAILMOX_AGE_SHA256
printf '{"tag_name":"v9.9.10","assets":[{"name":"age-v9.9.10-linux-amd64.tar.gz","browser_download_url":"file://%s/age.tar.gz","digest":"sha256:%s"}]}\n' \
    "$TEST_DIR" "$CHECKSUM" > "$TEST_DIR/latest.json"
export TAILMOX_AGE_RELEASE_API="file://$TEST_DIR/latest.json"
rm -f "$TEST_DIR/bin/age" "$TEST_DIR/bin/age-keygen"
install_post_quantum_age >/dev/null
"$TEST_DIR/bin/age-keygen" --help | grep -q -- '-pq'

printf 'post-quantum age installer tests passed\n'
