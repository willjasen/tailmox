#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY="${TAILMOX_REPOSITORY:-willjasen/tailmox}"
REF="${TAILMOX_INSTALL_REF:-dev}"
INSTALL_DIR="${TAILMOX_INSTALL_DIR:-/opt/tailmox}"
BIN_DIR="${TAILMOX_BIN_DIR:-/usr/local/bin}"
ARCHIVE_URL="${TAILMOX_ARCHIVE_URL:-https://github.com/${REPOSITORY}/archive/refs/heads/${REF}.tar.gz}"
IDENTITY_FILE="${TAILMOX_AGE_IDENTITY_FILE:-/etc/tailmox/identity.txt}"
SECURITY_FILE="${TAILMOX_SECURITY_FILE:-${TAILMOX_PVE_CONFIG_DIR:-/etc/pve}/tailmox/security.json}"

fail() {
    printf 'Tailmox installation failed: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

printf '\n  Tailmox installer\n\n'

if [[ "$EUID" -ne 0 && "${TAILMOX_ALLOW_NON_ROOT:-false}" != true ]]; then
    fail 'run this installer as root.'
fi

for command_name in curl tar pveversion; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "required command not found: $command_name"
done

PVE_VERSION=$(pveversion | sed -n 's/^pve-manager\/\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [[ "$PVE_VERSION" != 8 && "$PVE_VERSION" != 9 ]]; then
    fail "Proxmox VE 8 or 9 is required (found: ${PVE_VERSION:-unknown})."
fi

COMMAND_PATH="$BIN_DIR/tailmox"
if [[ -e "$COMMAND_PATH" || -L "$COMMAND_PATH" ]]; then
    if [[ ! -L "$COMMAND_PATH" || "$(readlink "$COMMAND_PATH")" != "$INSTALL_DIR/tailmox" ]]; then
        fail "$COMMAND_PATH is not managed by Tailmox; it was left unchanged."
    fi
fi

UPDATING=false
if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    if [[ ! -d "$INSTALL_DIR" || ! -f "$INSTALL_DIR/tailmox" ||
        ! -f "$INSTALL_DIR/tailmox.sh" ]]; then
        fail "$INSTALL_DIR is not a recognized Tailmox installation; it was left unchanged."
    fi
    if [[ -d "$INSTALL_DIR/.git" ]] &&
        [[ -n "$(git -C "$INSTALL_DIR" status --porcelain 2>/dev/null || printf 'unknown')" ]]; then
        fail "$INSTALL_DIR has local changes; commit or move them before updating."
    fi
    UPDATING=true
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tailmox-install.XXXXXX") ||
    fail 'could not create a temporary directory.'
ARCHIVE="$WORK_DIR/tailmox.tar.gz"
EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

printf 'Downloading Tailmox (%s)...\n' "$REF"
curl -fsSL --retry 3 --output "$ARCHIVE" "$ARCHIVE_URL" ||
    fail 'download did not complete.'
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" || fail 'downloaded archive is invalid.'

SOURCE_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)
if [[ -z "$SOURCE_DIR" || ! -f "$SOURCE_DIR/tailmox" || ! -f "$SOURCE_DIR/tailmox.sh" ]]; then
    fail 'downloaded archive does not contain a Tailmox release.'
fi

mkdir -p "$(dirname "$INSTALL_DIR")" "$BIN_DIR" ||
    fail 'could not create the installation directories.'
if [[ "$UPDATING" == true ]]; then
    BACKUP_DIR="$WORK_DIR/previous-install"
    mv "$INSTALL_DIR" "$BACKUP_DIR" || fail 'could not stage the existing installation.'
    if ! mv "$SOURCE_DIR" "$INSTALL_DIR"; then
        mv "$BACKUP_DIR" "$INSTALL_DIR" || true
        fail "could not update $INSTALL_DIR."
    fi
else
    mv "$SOURCE_DIR" "$INSTALL_DIR" || fail "could not install into $INSTALL_DIR."
fi
chmod +x "$INSTALL_DIR/tailmox" "$INSTALL_DIR/tailmox.sh"

if [[ ! -L "$COMMAND_PATH" ]] && ! ln -s "$INSTALL_DIR/tailmox" "$COMMAND_PATH"; then
    rm -rf "$INSTALL_DIR"
    if [[ "$UPDATING" == true && -d "${BACKUP_DIR:-}" ]]; then
        mv "$BACKUP_DIR" "$INSTALL_DIR" || true
    fi
    fail "could not create $COMMAND_PATH."
fi

if [[ "$UPDATING" == true ]]; then
    printf '\nTailmox is updated from the %s branch.\n' "$REF"
else
    printf '\nTailmox is installed from the %s branch.\n' "$REF"
fi

printf '\nStaging this Proxmox host with Tailscale and the Tailmox monitor...\n\n'
if ! "$INSTALL_DIR/tailmox" stage "$@"; then
    fail 'Tailmox was installed, but staging did not complete.'
fi

if [[ ! -f "$IDENTITY_FILE" ]]; then
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        fail 'an interactive terminal is required to create or import the age identity.'
    fi
    CLUSTER_RECIPIENT=''
    if [[ -f "$SECURITY_FILE" ]]; then
        CLUSTER_RECIPIENT=$(python3 -c \
            'import json, sys; value=json.load(open(sys.argv[1])).get("ageRecipient"); print(value or "")' \
            "$SECURITY_FILE" 2>/dev/null) ||
            fail "the cluster security registry is invalid: $SECURITY_FILE"
    fi
    printf '\nNo Tailmox age identity is installed on this host.\n' >/dev/tty
    if [[ -n "$CLUSTER_RECIPIENT" ]]; then
        RECIPIENT_FINGERPRINT=$(printf '%s' "$CLUSTER_RECIPIENT" |
            openssl dgst -sha256 | awk '{print substr($NF, 1, 16)}')
        RECIPIENT_PREVIEW="${CLUSTER_RECIPIENT:0:20}...${CLUSTER_RECIPIENT: -8}"
        printf 'The Proxmox cluster already uses age recipient %s.\n' \
            "$RECIPIENT_PREVIEW" >/dev/tty
        printf 'Recipient fingerprint: %s\n' "$RECIPIENT_FINGERPRINT" >/dev/tty
        printf 'Import the matching private identity to join this Tailmox cluster.\n' >/dev/tty
        IDENTITY_ACTION=import
    else
        printf 'Create a new identity or import the cluster identity? [create/import]: ' >/dev/tty
        IFS= read -r IDENTITY_ACTION </dev/tty
    fi
    case "${IDENTITY_ACTION:-create}" in
        create|c)
            printf '\nCreating a post-quantum Tailmox age identity...\n' >/dev/tty
            IDENTITY_DETAILS=$(cd "$INSTALL_DIR" && python3 -c \
                'import hashlib, tailmox_config; result=tailmox_config.create_identity(); recipient=result["recipient"]; print(recipient[:20] + "..." + recipient[-8:]); print(hashlib.sha256(recipient.encode()).hexdigest()[:16])') ||
                fail 'the age identity could not be created.'
            CREATED_RECIPIENT=$(sed -n '1p' <<< "$IDENTITY_DETAILS")
            CREATED_FINGERPRINT=$(sed -n '2p' <<< "$IDENTITY_DETAILS")
            unset IDENTITY_DETAILS
            printf 'Created age recipient: %s\n' "$CREATED_RECIPIENT" >/dev/tty
            printf 'Recipient fingerprint: %s\n' "$CREATED_FINGERPRINT" >/dev/tty
            printf 'The private identity is stored root-only at %s. Back up that file securely.\n\n' \
                "$IDENTITY_FILE" >/dev/tty
            ;;
        import|i)
            printf 'Paste the private Tailmox age identity: ' >/dev/tty
            IFS= read -r -s IMPORTED_IDENTITY </dev/tty
            printf '\n' >/dev/tty
            if ! printf '%s\n' "$IMPORTED_IDENTITY" | (cd "$INSTALL_DIR" && python3 -c \
                'import sys, tailmox_config; tailmox_config.install_identity(sys.stdin.read())'); then
                unset IMPORTED_IDENTITY
                fail 'the age identity could not be imported.'
            fi
            unset IMPORTED_IDENTITY
            printf 'The Tailmox age identity was imported.\n' >/dev/tty
            ;;
        *)
            fail 'identity setup must be either create or import.'
            ;;
    esac
else
    printf 'The existing Tailmox age identity was preserved.\n'
fi

TAILSCALE_DNS_NAME=$(tailscale status --json 2>/dev/null |
    jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)
if [[ -n "$TAILSCALE_DNS_NAME" ]]; then
    MAGICDNS_DOMAIN=${TAILSCALE_DNS_NAME#*.}
    printf '\nMonitor: https://%s:8088/monitor/\n' "$TAILSCALE_DNS_NAME"
    if [[ -n "$MAGICDNS_DOMAIN" && "$MAGICDNS_DOMAIN" != "$TAILSCALE_DNS_NAME" ]]; then
        printf 'Service monitor: https://tailmox.%s:8088/monitor/\n' "$MAGICDNS_DOMAIN"
    fi
else
    printf '\nMonitor: http://127.0.0.1:8088/monitor/\n'
fi
printf 'Staging is complete. Run tailmox cluster when every host is ready.\n\n'
