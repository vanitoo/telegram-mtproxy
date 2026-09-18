#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/vanitoo/telegram-mtproxy.git"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/telegram-mtproxy}"
CONTAINER_NAME="mtproxy"

ENABLE_DAILY_REFRESH="${ENABLE_DAILY_REFRESH:-1}"
CRON_SCHEDULE="${CRON_SCHEDULE:-15 4 * * *}"
CRON_MARKER="# telegram-mtproxy-refresh"

echo "[MTProxy] One-click installer"

for cmd in git docker curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[MTProxy] ERROR: $cmd is not installed"
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    echo "[MTProxy] ERROR: Docker Compose v2 is required"
    exit 1
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[MTProxy] Updating existing installation in $INSTALL_DIR..."
    cd "$INSTALL_DIR"
    git pull --ff-only
else
    if [[ -e "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
        echo "[MTProxy] ERROR: $INSTALL_DIR exists and is not an empty Git repository"
        exit 1
    fi

    echo "[MTProxy] Cloning repository to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    git clone --branch "$BRANCH" --depth=1 "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "[MTProxy] Created .env from .env.example"
else
    echo "[MTProxy] Keeping existing .env"
fi

if ! grep -q '^EXTERNAL_IP=.' .env; then
    PUBLIC_IP="$(
        curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
        curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null ||
        curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null ||
        true
    )"
    PUBLIC_IP="$(printf '%s' "$PUBLIC_IP" | tr -d '[:space:]')"

    if [[ -n "$PUBLIC_IP" ]]; then
        sed -i "s/^EXTERNAL_IP=.*/EXTERNAL_IP=$PUBLIC_IP/" .env
        echo "[MTProxy] Detected public IPv4: $PUBLIC_IP"
    else
        echo "[MTProxy] WARNING: public IPv4 was not detected; container will retry automatically"
    fi
fi

echo "[MTProxy] Building and starting..."
docker compose up -d --build

echo -n "[MTProxy] Waiting for container"
for _ in $(seq 1 30); do
    STATUS="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    if [[ "$STATUS" == "running" ]]; then
        echo
        break
    fi
    echo -n "."
    sleep 1
done

STATUS="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
if [[ "$STATUS" != "running" ]]; then
    echo
    echo "[MTProxy] ERROR: container is not running (status=${STATUS:-unknown})"
    docker compose logs --tail=200 mtproxy || true
    exit 1
fi

install_daily_refresh() {
    if [[ "$ENABLE_DAILY_REFRESH" != "1" ]]; then
        echo "[MTProxy] Daily Telegram config refresh is disabled"
        return
    fi

    local docker_bin install_dir_q docker_bin_q cron_command
    docker_bin="$(command -v docker)"
    install_dir_q="$(printf '%q' "$INSTALL_DIR")"
    docker_bin_q="$(printf '%q' "$docker_bin")"
    cron_command="cd $install_dir_q && $docker_bin_q compose restart mtproxy >/dev/null 2>&1"

    if [[ "${EUID}" -eq 0 ]]; then
        cat > /etc/cron.d/telegram-mtproxy <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_SCHEDULE root $cron_command $CRON_MARKER
EOF
        chmod 0644 /etc/cron.d/telegram-mtproxy

        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now cron >/dev/null 2>&1 ||
                systemctl enable --now crond >/dev/null 2>&1 ||
                true
        fi

        echo "[MTProxy] Daily Telegram config refresh installed in /etc/cron.d/telegram-mtproxy"
        echo "[MTProxy] Schedule: $CRON_SCHEDULE"
    elif command -v crontab >/dev/null 2>&1; then
        local existing
        existing="$(crontab -l 2>/dev/null || true)"
        {
            printf '%s\n' "$existing" | sed "/${CRON_MARKER//\//\\/}$/d"
            printf '%s %s %s\n' "$CRON_SCHEDULE" "$cron_command" "$CRON_MARKER"
        } | crontab -

        echo "[MTProxy] Daily Telegram config refresh installed in the current user's crontab"
        echo "[MTProxy] Schedule: $CRON_SCHEDULE"
    else
        echo "[MTProxy] WARNING: cron/crontab is not available; daily refresh was not installed"
    fi
}

install_daily_refresh

echo
echo "[MTProxy] Telegram link:"
LINK="$(
    docker compose logs mtproxy 2>/dev/null |
    grep -o 'tg://proxy?[^[:space:]]*' |
    tail -n 1 ||
    true
)"

if [[ -n "$LINK" ]]; then
    echo "$LINK"
else
    echo "[MTProxy] Link is not in logs yet. Run:"
    echo "cd $INSTALL_DIR && docker compose logs mtproxy | grep -o 'tg://proxy?[^[:space:]]*' | tail -n 1"
fi
