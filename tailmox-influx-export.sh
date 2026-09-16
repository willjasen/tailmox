#!/usr/bin/env bash

set -Eeuo pipefail

TAILMOX_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INTERVAL_SECONDS="${TAILMOX_INFLUX_INTERVAL_SECONDS:-60}"
ENV_FILE="${TAILMOX_INFLUX_ENV_FILE:-/etc/tailmox-monitor.env}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

INFLUX_URL="${TAILMOX_INFLUXDB_URL:-}"
INFLUX_TOKEN="${TAILMOX_INFLUXDB_TOKEN:-}"
INFLUX_ORG="${TAILMOX_INFLUXDB_ORG:-}"
INFLUX_BUCKET="${TAILMOX_INFLUXDB_BUCKET:-}"

if [[ -z "$INFLUX_URL" || -z "$INFLUX_TOKEN" || -z "$INFLUX_ORG" || -z "$INFLUX_BUCKET" ]]; then
    IFS=$'\t' read -r INFLUX_URL INFLUX_TOKEN INFLUX_ORG INFLUX_BUCKET < <(
        TAILMOX_CONFIG_FILE="${TAILMOX_CONFIG_FILE:-/etc/pve/tailmox/config.age}" \
        TAILMOX_AGE_IDENTITY_FILE="${TAILMOX_AGE_IDENTITY_FILE:-/etc/tailmox/identity.txt}" \
        /usr/bin/python3 -c '
import tailmox_config
config = tailmox_config.current_config()["influxdb"]
print("\t".join(str(config.get(key, "")) for key in ("url", "token", "org", "bucket")))
' 2>/dev/null
    )
fi

if [[ -z "$INFLUX_URL" || -z "$INFLUX_TOKEN" || -z "$INFLUX_ORG" || -z "$INFLUX_BUCKET" ]]; then
    printf 'InfluxDB configuration is incomplete.\n' >&2
    exit 1
fi

escape_tag() {
    local value=${1:-}
    value=${value//\\/\\\\}
    value=${value//,/\\,}
    value=${value//=/\\=}
    value=${value// /\\ }
    printf '%s' "$value"
}

collect_once() {
    local output_file payload_file hostname timestamp
    output_file=$(mktemp)
    payload_file=$(mktemp)
    trap 'rm -f "$output_file" "$payload_file"' RETURN
    hostname=$(hostname -s)
    timestamp=$(date +%s%N)

    if ! TAILMOX_MONITOR_OUTPUT=true "$TAILMOX_ROOT/tailmox" test >"$output_file" 2>&1; then
        :
    fi

    local tcp_pattern='TCP port ([0-9]+) is (not )?available; latency ([0-9.]+) ms\.'
    while IFS=$'\t' read -r line; do
        if [[ "$line" == __TAILMOX_MONITOR_ICMP__* ]]; then
            IFS=$'\t' read -r _ node packet_size status received sent average maximum _ <<<"$line"
            if [[ "$received" != unknown && "$sent" != unknown &&
                "$average" != unknown && "$maximum" != unknown ]]; then
                printf 'tailmox_icmp,host=%s,node=%s,packet_size=%s average_ms=%s,maximum_ms=%s,packets_received=%si,packets_sent=%si,status="%s" %s\n' \
                    "$(escape_tag "$hostname")" "$(escape_tag "$node")" "$packet_size" \
                    "$average" "$maximum" "$received" "$sent" "$status" "$timestamp" >>"$payload_file"
            fi
        elif [[ "$line" =~ $tcp_pattern ]]; then
            local available=1
            [[ -n "${BASH_REMATCH[2]}" ]] && available=0
            printf 'tailmox_tcp,host=%s,port=%s latency_ms=%s,available=%si %s\n' \
                "$(escape_tag "$hostname")" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "$available" "$timestamp" >>"$payload_file"
        fi
    done < <(sed $'s/\033\\[[0-9;]*m//g' "$output_file")

    local cmap_pattern='^([^[:space:]]+) \(([^)]+)\) = ([0-9]+)$'
    while IFS= read -r line; do
        if [[ "$line" =~ $cmap_pattern ]]; then
            local cmap_path="${BASH_REMATCH[1]}"
            local cmap_type="${BASH_REMATCH[2]}"
            local cmap_value="${BASH_REMATCH[3]}"
            if [[ "$cmap_path" == stats.knet.node*.link*.* && "$cmap_type" != str ]]; then
                local cmap_node cmap_link cmap_metric cmap_tags
                cmap_node=${cmap_path#stats.knet.node}
                cmap_node=${cmap_node%%.*}
                cmap_link=${cmap_path#*.link}
                cmap_link=${cmap_link%%.*}
                cmap_metric=${cmap_path##*.}
                cmap_tags="host=$(escape_tag "$hostname"),path=$(escape_tag "$cmap_path"),family=knet,scope=node${cmap_node},nodeid=$(escape_tag "$cmap_node"),link=$(escape_tag "$cmap_link"),metric=$(escape_tag "$cmap_metric")"
                printf 'tailmox_corosync_cmap_stat,%s value=%si %s\n' "$cmap_tags" "$cmap_value" "$timestamp" >>"$payload_file"
            fi
        fi
    done < <(corosync-cmapctl -m stats 2>/dev/null || true)

    if [[ -s "$payload_file" ]]; then
        curl --fail --silent --show-error \
            --max-time 10 \
            --header "Authorization: Token $INFLUX_TOKEN" \
            --header 'Content-Type: text/plain; charset=utf-8' \
            --data-binary "@$payload_file" \
            "$INFLUX_URL/api/v2/write?$(printf 'org=%s&bucket=%s&precision=ns' \
                "$(printf '%s' "$INFLUX_ORG" | jq -sRr @uri)" \
                "$(printf '%s' "$INFLUX_BUCKET" | jq -sRr @uri)")"
    fi
}

while :; do
    collect_once || true
    sleep "$INTERVAL_SECONDS"
done
