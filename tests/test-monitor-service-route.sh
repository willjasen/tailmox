#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT_DIR/tailmox.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

if ! grep -Fq \
    'configure_tailscale_serve "--service=svc:${TAILMOX_TAILSCALE_SERVICE_NAME}" --bg --https=443 localhost:8088' \
    "$INSTALLER"; then
    printf 'FAIL: configurable shared Tailmox service does not route HTTPS port 443 to the monitor\n'
    exit 1
fi

if ! grep -Fq 'resolvconf' "$INSTALLER"; then
    printf 'FAIL: Tailscale DNS setup does not install resolvconf\n'
    exit 1
fi

if ! grep -Fq \
    'TAILMOX_TAILSCALE_SERVICE_NAME="${TAILMOX_TAILSCALE_SERVICE_NAME:-tailmox}"' \
    "$INSTALLER"; then
    printf 'FAIL: shared Tailmox service does not retain a compatible default\n'
    exit 1
fi

if grep -Fq \
    'tailscale serve --service=svc:tailmox https+insecure://localhost:8006' \
    "$INSTALLER" ||
    grep -Fq \
        'tailscale serve --service=svc:tailmox --https=8088' \
        "$INSTALLER"; then
    printf 'FAIL: obsolete shared Tailmox service route is still configured\n'
    exit 1
fi

export TAILMOX_LIBRARY_MODE=true
export TAILMOX_LOG_DIR="$TEST_DIR/logs"
mkdir -p "$TAILMOX_LOG_DIR" "$TEST_DIR/bin"

source "$INSTALLER"

cat > "$TEST_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAILMOX_TEST_CALLS"
case "${TAILMOX_TEST_CURL_RESULT:-success}" in
    success)
        printf '%s\n' '200'
        exit 0
        ;;
    protected)
        printf '%s\n' '403'
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/curl"

export PATH="$TEST_DIR/bin:$PATH"
export TAILMOX_TEST_CALLS="$TEST_DIR/calls"

: > "$TAILMOX_TEST_CALLS"
TAILMOX_TEST_CURL_RESULT=success
export TAILMOX_TEST_CURL_RESULT
verify_monitor_url 'https://tailmox1.example.ts.net:8088/monitor' >/dev/null
grep -Fq -- '--retry 5 --retry-delay 1 --retry-all-errors --output /dev/null --write-out %{http_code} https://tailmox1.example.ts.net:8088/monitor' "$TAILMOX_TEST_CALLS" || {
    printf 'FAIL: monitor availability check did not use bounded retries, HTTP status capture, and the full URL\n'
    exit 1
}

TAILMOX_TEST_CURL_RESULT=protected
export TAILMOX_TEST_CURL_RESULT
if ! verify_monitor_url 'https://dev-tailmox.example.ts.net/' >/dev/null 2>&1; then
    printf 'FAIL: a protected Tailscale service URL should remain reachable even when it answers 403\n'
    exit 1
fi

TAILMOX_TEST_CURL_RESULT=fail
export TAILMOX_TEST_CURL_RESULT
if verify_monitor_url 'https://dev-tailmox.example.ts.net/' >/dev/null 2>&1; then
    printf 'FAIL: an unavailable monitor URL did not stop setup\n'
    exit 1
fi

grep -Fq 'node_monitor_url="https://${TAILSCALE_DNS_NAME}:8088/monitor"' "$INSTALLER" || {
    printf 'FAIL: node monitor URL does not use its full MagicDNS name\n'
    exit 1
}
grep -Fq 'service_monitor_url="https://${TAILMOX_TAILSCALE_SERVICE_NAME}.${magicdns_domain}/"' "$INSTALLER" || {
    printf 'FAIL: service monitor URL does not use the tailnet MagicDNS domain\n'
    exit 1
}

grep -Fq 'verify_monitor_url "$node_monitor_url" || return 1' "$INSTALLER" || {
    printf 'FAIL: monitor health check still curls the shared service URL instead of the device URL\n'
    exit 1
}

printf 'PASS: monitor routes print and verify their full Tailscale URLs\n'
