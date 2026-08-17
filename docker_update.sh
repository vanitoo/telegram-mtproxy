#!/bin/bash
set -e

#git pull
docker compose up -d --build

sleep 3

docker compose logs mtproxy \
  | grep -o 'tg://proxy?[^[:space:]]*' \
  | tail -n 1
