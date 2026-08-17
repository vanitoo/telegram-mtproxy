#!/bin/bash
set -euo pipefail

PORT="${PORT:-443}"
STATS_PORT="${STATS_PORT:-2398}"
DOMAIN="${DOMAIN:-www.cloudflare.com}"
WORKERS="${WORKERS:-1}"
PROXY_TAG="${PROXY_TAG:-}"
EXTERNAL_IP="${EXTERNAL_IP:-}"

mkdir -p /data

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
# Secret
# ----------------------------------------------------------

if [[ ! -s /data/secret ]]; then
    echo "[MTProxy] Generating new secret..."
    openssl rand -hex 16 > /data/secret
    chmod 600 /data/secret
fi

SECRET="$(tr -d '[:space:]' < /data/secret)"


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
# Base arguments
# ----------------------------------------------------------

ARGS=(
    -u mtproxy
    -p "$STATS_PORT"
    -H "$PORT"
    -S "$SECRET"
    --http-stats
    --domain "$DOMAIN"
    --aes-pwd /data/proxy-secret
    /data/proxy-multi.conf
    -M "$WORKERS"
)


# ----------------------------------------------------------
# Docker NAT
# ----------------------------------------------------------

INTERNAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if [[ -n "$EXTERNAL_IP" && -n "$INTERNAL_IP" && "$INTERNAL_IP" != "$EXTERNAL_IP" ]]; then
    echo "[MTProxy] NAT: ${INTERNAL_IP}:${EXTERNAL_IP}"
    ARGS+=(--nat-info "${INTERNAL_IP}:${EXTERNAL_IP}")
fi


# ----------------------------------------------------------
# Optional proxy tag
# ----------------------------------------------------------

if [[ -n "$PROXY_TAG" ]]; then
    ARGS+=(-P "$PROXY_TAG")
fi


# ----------------------------------------------------------
# Fake TLS client secret
# ----------------------------------------------------------

DOMAIN_HEX="$(
    printf '%s' "$DOMAIN" |
    od -An -tx1 |
    tr -d ' \n'
)"

EE_SECRET="ee${SECRET}${DOMAIN_HEX}"


# ----------------------------------------------------------
# Output
# ----------------------------------------------------------

echo
echo "[MTProxy] Starting"
echo "[MTProxy] Port: $PORT"
echo "[MTProxy] Fake TLS domain: $DOMAIN"
echo "[MTProxy] Client secret: $EE_SECRET"

if [[ -n "$EXTERNAL_IP" ]]; then
    echo
    echo "[MTProxy] Telegram link:"
    echo "tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${EE_SECRET}"
fi

echo


# ----------------------------------------------------------
# Start MTProxy
# ----------------------------------------------------------

exec /usr/local/bin/mtproto-proxy "${ARGS[@]}"
