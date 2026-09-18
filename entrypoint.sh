#!/bin/bash
set -euo pipefail

PORT="${PORT:-443}"
STATS_PORT="${STATS_PORT:-2398}"
DOMAIN="${DOMAIN:-www.cloudflare.com}"
WORKERS="${WORKERS:-1}"
PROXY_TAG="${PROXY_TAG:-}"
EXTERNAL_IP="${EXTERNAL_IP:-}"
CONTROL_DIR="${CONTROL_DIR:-/control}"
LEGACY_SECRET_ENABLED="${LEGACY_SECRET_ENABLED:-true}"
SECRET_RELOAD_INTERVAL="${SECRET_RELOAD_INTERVAL:-1}"

MANIFEST_FILE="${CONTROL_DIR}/active_secrets.txt"
ACK_FILE="${CONTROL_DIR}/active_secrets.applied.sha256"
SECRET_RE='^[0-9a-fA-F]{32}$'
PROXY_PID=""
CURRENT_MANIFEST_HASH=""
LAST_REJECTED_HASH=""

mkdir -p /data "$CONTROL_DIR"

echo "[MTProxy] Updating Telegram configuration..."

curl -fsSL \
  https://core.telegram.org/getProxySecret \
  -o /data/proxy-secret.tmp

curl -fsSL \
  https://core.telegram.org/getProxyConfig \
  -o /data/proxy-multi.conf.tmp

test -s /data/proxy-secret.tmp
test "$(stat -c%s /data/proxy-multi.conf.tmp)" -ge 64

mv /data/proxy-secret.tmp /data/proxy-secret
mv /data/proxy-multi.conf.tmp /data/proxy-multi.conf


# ----------------------------------------------------------
# Legacy secret
# ----------------------------------------------------------

if [[ ! -s /data/secret ]]; then
    echo "[MTProxy] Generating new legacy secret..."
    openssl rand -hex 16 > /data/secret
    chmod 600 /data/secret
fi

SECRET="$(tr -d '[:space:]' < /data/secret)"
if ! [[ "$SECRET" =~ $SECRET_RE ]]; then
    echo "[MTProxy] ERROR: /data/secret must contain exactly 32 hexadecimal characters"
    exit 1
fi
SECRET="${SECRET,,}"

case "${LEGACY_SECRET_ENABLED,,}" in
    1|true|yes|on) LEGACY_SECRET_ENABLED=true ;;
    *) LEGACY_SECRET_ENABLED=false ;;
esac

if ! [[ "$SECRET_RELOAD_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "[MTProxy] ERROR: SECRET_RELOAD_INTERVAL must be a positive number"
    exit 1
fi


# ----------------------------------------------------------
# Detect external/public IPv4
# ----------------------------------------------------------

if [[ -z "$EXTERNAL_IP" ]]; then
    echo "[MTProxy] Detecting public IPv4..."

    EXTERNAL_IP="$(
        curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
        curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null ||
        curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null ||
        true
    )"

    EXTERNAL_IP="$(echo "$EXTERNAL_IP" | tr -d '[:space:]')"
fi

if [[ -n "$EXTERNAL_IP" ]]; then
    echo "[MTProxy] Public IPv4: $EXTERNAL_IP"
else
    echo "[MTProxy] WARNING: unable to detect public IPv4"
fi


# ----------------------------------------------------------
# Helpers
# ----------------------------------------------------------

manifest_hash() {
    if [[ -f "$MANIFEST_FILE" ]]; then
        sha256sum "$MANIFEST_FILE" | awk '{print $1}'
    else
        printf '' | sha256sum | awk '{print $1}'
    fi
}

write_ack() {
    local value="$1"
    local tmp="${ACK_FILE}.tmp.$$"
    printf '%s\n' "$value" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$ACK_FILE"
}

prepare_args() {
    local dynamic_count=0
    local total_count=0
    local raw secret
    declare -A seen=()

    ARGS=(
        -u mtproxy
        -p "$STATS_PORT"
        -H "$PORT"
    )

    if [[ "$LEGACY_SECRET_ENABLED" == "true" ]]; then
        ARGS+=(-S "$SECRET")
        seen["$SECRET"]=1
        total_count=$((total_count + 1))
    fi

    if [[ -f "$MANIFEST_FILE" ]]; then
        while IFS= read -r raw || [[ -n "$raw" ]]; do
            secret="$(printf '%s' "$raw" | tr -d '[:space:]')"
            [[ -z "$secret" ]] && continue

            if ! [[ "$secret" =~ $SECRET_RE ]]; then
                echo "[MTProxy] ERROR: invalid secret in $MANIFEST_FILE; keeping current proxy process"
                return 1
            fi

            secret="${secret,,}"
            if [[ -z "${seen[$secret]+x}" ]]; then
                ARGS+=(-S "$secret")
                seen["$secret"]=1
                dynamic_count=$((dynamic_count + 1))
                total_count=$((total_count + 1))
            fi
        done < "$MANIFEST_FILE"
    fi

    if (( total_count == 0 )); then
        echo "[MTProxy] ERROR: no active secrets; enable legacy secret or provision at least one managed secret"
        return 1
    fi

    ARGS+=(
        --http-stats
        --domain "$DOMAIN"
        --aes-pwd /data/proxy-secret
        /data/proxy-multi.conf
        -M "$WORKERS"
    )

    INTERNAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "$EXTERNAL_IP" && -n "$INTERNAL_IP" && "$INTERNAL_IP" != "$EXTERNAL_IP" ]]; then
        ARGS+=(--nat-info "${INTERNAL_IP}:${EXTERNAL_IP}")
    fi

    if [[ -n "$PROXY_TAG" ]]; then
        ARGS+=(-P "$PROXY_TAG")
    fi

    PREPARED_DYNAMIC_COUNT="$dynamic_count"
    PREPARED_TOTAL_COUNT="$total_count"
}

start_proxy() {
    local applied_hash="$1"

    echo "[MTProxy] Starting mtproto-proxy: secrets=$PREPARED_TOTAL_COUNT managed=$PREPARED_DYNAMIC_COUNT legacy=$LEGACY_SECRET_ENABLED"
    /usr/local/bin/mtproto-proxy "${ARGS[@]}" &
    PROXY_PID=$!

    sleep 0.5
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "[MTProxy] ERROR: mtproto-proxy exited during startup"
        wait "$PROXY_PID" || true
        PROXY_PID=""
        return 1
    fi

    write_ack "$applied_hash"
    CURRENT_MANIFEST_HASH="$applied_hash"
    echo "[MTProxy] Applied managed-secret manifest: ${applied_hash:0:12}..."
}

stop_proxy() {
    if [[ -n "$PROXY_PID" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill -TERM "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    PROXY_PID=""
}

shutdown() {
    echo "[MTProxy] Stopping..."
    stop_proxy
    exit 0
}

trap shutdown TERM INT


# ----------------------------------------------------------
# Fake TLS legacy link (kept for backwards compatibility)
# ----------------------------------------------------------

DOMAIN_HEX="$(
    printf '%s' "$DOMAIN" |
    od -An -tx1 |
    tr -d ' \n'
)"

EE_SECRET="ee${SECRET}${DOMAIN_HEX}"

echo
echo "[MTProxy] Supervisor starting"
echo "[MTProxy] Port: $PORT"
echo "[MTProxy] Fake TLS domain: $DOMAIN"
echo "[MTProxy] Managed secrets: $MANIFEST_FILE"
echo "[MTProxy] Legacy secret enabled: $LEGACY_SECRET_ENABLED"

if [[ "$LEGACY_SECRET_ENABLED" == "true" && -n "$EXTERNAL_IP" ]]; then
    echo
    echo "[MTProxy] Legacy Telegram link:"
    echo "tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${EE_SECRET}"
fi
echo


# ----------------------------------------------------------
# Start and watch managed secrets
# ----------------------------------------------------------

INITIAL_HASH="$(manifest_hash)"
if ! prepare_args; then
    exit 1
fi
start_proxy "$INITIAL_HASH"

while true; do
    sleep "$SECRET_RELOAD_INTERVAL"

    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        set +e
        wait "$PROXY_PID"
        code=$?
        set -e
        echo "[MTProxy] ERROR: mtproto-proxy exited unexpectedly with code $code"
        exit "$code"
    fi

    NEW_HASH="$(manifest_hash)"
    if [[ "$NEW_HASH" == "$CURRENT_MANIFEST_HASH" ]]; then
        continue
    fi

    if ! prepare_args; then
        if [[ "$NEW_HASH" != "$LAST_REJECTED_HASH" ]]; then
            echo "[MTProxy] Managed-secret manifest rejected: ${NEW_HASH:0:12}..."
            LAST_REJECTED_HASH="$NEW_HASH"
        fi
        continue
    fi

    echo "[MTProxy] Managed-secret manifest changed; reloading proxy"
    stop_proxy

    if ! start_proxy "$NEW_HASH"; then
        exit 1
    fi
    LAST_REJECTED_HASH=""
done
