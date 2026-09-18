# 🚀 Telegram MTProxy in Docker

[![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Telegram](https://img.shields.io/badge/Telegram-MTProxy-26A5E4?style=flat-square&logo=telegram&logoColor=white)](https://github.com/TelegramMessenger/MTProxy)
![Default port](https://img.shields.io/badge/default_port-443-success?style=flat-square)
![Auto refresh](https://img.shields.io/badge/Telegram_config-daily_refresh-success?style=flat-square)

Docker-обёртка для официального **Telegram MTProxy** с Fake TLS, постоянным клиентским секретом, автоматическим определением публичного IPv4 и ежедневным обновлением конфигурации Telegram.

> Проект использует официальный [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) и собирает бинарный файл из исходников внутри Docker.

---

## ✨ Возможности

- 🐳 запуск через Docker Compose;
- 🔐 Fake TLS;
- 🔑 автоматическая генерация постоянного клиентского секрета;
- 🌍 автоматическое определение публичного IPv4;
- 🔄 загрузка свежих `proxy-secret` и `proxy-multi.conf` при каждом старте;
- 🕓 ежедневное обновление Telegram-конфигурации через cron;
- 💾 сохранение секрета и runtime-данных в `./data`;
- 🧹 ротация Docker-логов: до 3 файлов по 10 MB;
- ⬆️ обновление проекта одной командой через `docker_update.sh`.

---

## ⚡ One-click установка

### Требования

На сервере должны быть установлены:

- Linux;
- Docker Engine;
- Docker Compose v2;
- Git;
- curl;
- cron — для ежедневного автоматического обновления конфигурации Telegram.

Также необходимо разрешить входящий TCP-трафик на порт прокси. По умолчанию используется **443/tcp**.

### Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/vanitoo/telegram-mtproxy/refs/heads/main/install.sh)
```

Установщик:

1. клонирует проект в `/opt/telegram-mtproxy`;
2. создаёт `.env` из `.env.example`, если файла ещё нет;
3. пытается определить публичный IPv4;
4. собирает и запускает MTProxy;
5. устанавливает ежедневный cron для обновления Telegram-конфигурации;
6. выводит готовую ссылку `tg://proxy?... `.

При повторном запуске существующие `.env` и `data/` **не удаляются**. Репозиторий обновляется через `git pull --ff-only`, после чего контейнер пересобирается.

---

## 🔗 Получить ссылку подключения

```bash
cd /opt/telegram-mtproxy
docker compose logs mtproxy | grep -o 'tg://proxy?[^[:space:]]*' | tail -n 1
```

Результат выглядит так:

```text
tg://proxy?server=203.0.113.10&port=443&secret=ee...
```

Откройте ссылку на устройстве с Telegram.

---

## ⚙️ Настройки

Все пользовательские настройки находятся в `.env`.

| Переменная | Значение по умолчанию | Назначение |
| --- | --- | --- |
| `PORT` | `443` | TCP-порт MTProxy |
| `STATS_PORT` | `2398` | Внутренний HTTP-порт статистики |
| `DOMAIN` | `www.cloudflare.com` | Домен Fake TLS |
| `WORKERS` | `1` | Количество worker-процессов |
| `EXTERNAL_IP` | определяется автоматически | Публичный IPv4 сервера |
| `PROXY_TAG` | пусто | Необязательный тег от `@MTProxybot` |

Пример:

```dotenv
PORT=443
STATS_PORT=2398
DOMAIN=www.cloudflare.com
WORKERS=1
EXTERNAL_IP=
PROXY_TAG=
```

Если сервер работает на нестандартном внешнем порту, измените только локальный `.env`, например:

```dotenv
PORT=8443
```

Файл `.env` исключён из Git и не перезаписывается при обычном обновлении проекта.

---

## 🔄 Автоматическое обновление Telegram-конфигурации

При каждом запуске контейнера `entrypoint.sh` получает свежие файлы напрямую с Telegram:

```text
https://core.telegram.org/getProxySecret
https://core.telegram.org/getProxyConfig
```

Они сохраняются как:

```text
/data/proxy-secret
/data/proxy-multi.conf
```

Сначала данные скачиваются во временные файлы, затем проверяются и только после успешной проверки заменяют рабочую конфигурацию.

### Ежедневное обновление

One-click installer автоматически создаёт cron-задачу:

```cron
15 4 * * * ... docker compose restart mtproxy
```

То есть каждый день в **04:15 по времени сервера** контейнер перезапускается. При старте `entrypoint.sh` скачивает свежую Telegram-конфигурацию и затем снова запускает MTProxy.

Это **не выполняет**:

- `git pull`;
- Docker rebuild;
- смену `data/secret`;
- изменение клиентской ссылки.

Во время рестарта возможен короткий разрыв существующих соединений.

При запуске installer от root задание сохраняется здесь:

```text
/etc/cron.d/telegram-mtproxy
```

Проверить:

```bash
cat /etc/cron.d/telegram-mtproxy
```

Для пользовательской установки скрипт использует обычный `crontab`, если он доступен.

Расписание можно изменить при установке:

```bash
CRON_SCHEDULE="30 3 * * *" bash <(curl -Ls https://raw.githubusercontent.com/vanitoo/telegram-mtproxy/refs/heads/main/install.sh)
```

Или полностью отключить создание cron:

```bash
ENABLE_DAILY_REFRESH=0 bash <(curl -Ls https://raw.githubusercontent.com/vanitoo/telegram-mtproxy/refs/heads/main/install.sh)
```

---

## 🧠 Как это работает

```text
                 ┌──────────────────────┐
                 │   docker-compose     │
                 └──────────┬───────────┘
                            │
                            ▼
                 ┌──────────────────────┐
                 │    entrypoint.sh     │
                 └──────────┬───────────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
              ▼                           ▼
  getProxySecret / Config          data/secret
       from Telegram              постоянный секрет
              │                           │
              └─────────────┬─────────────┘
                            ▼
                 ┌──────────────────────┐
                 │   mtproto-proxy      │
                 │   + Fake TLS         │
                 └──────────────────────┘
```

Если `EXTERNAL_IP` отличается от IP внутри Docker bridge, `entrypoint.sh` автоматически добавляет `--nat-info`.

---

## 🛠 Управление

### Состояние

```bash
cd /opt/telegram-mtproxy
docker compose ps
```

### Логи

```bash
docker compose logs -f mtproxy
```

Для контейнера настроена ротация Docker-логов:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

### Перезапуск

```bash
docker compose restart mtproxy
```

При перезапуске заново загружается конфигурация Telegram.

### Применить изменения из `.env`

```bash
docker compose up -d --force-recreate mtproxy
```

### Обновить код проекта и пересобрать

```bash
./docker_update.sh
```

Скрипт выполняет:

```text
git pull --ff-only
        ↓
docker compose up -d --build
        ↓
вывод актуальной tg:// ссылки
```

### Остановить

```bash
docker compose down
```

Директория `./data` при этом сохраняется.

---

## 🔐 Секрет и постоянные данные

При первом запуске создаётся:

```text
data/secret
```

Этот файл определяет клиентский secret и, соответственно, ссылку подключения.

**Не удаляйте `data/secret`**, если хотите сохранить уже выданные пользователям подключения.

Содержимое `data/`:

| Файл | Назначение |
| --- | --- |
| `.gitkeep` | сохраняет каталог в Git |
| `secret` | постоянный локальный клиентский секрет |
| `proxy-secret` | актуальный серверный secret Telegram |
| `proxy-multi.conf` | актуальная конфигурация Telegram |

Чтобы намеренно создать новый клиентский secret:

```bash
docker compose down
rm data/secret
docker compose up -d
```

После этого старая ссылка подключения перестанет работать.

> Не публикуйте содержимое `data/secret` и полную `tg://proxy` ссылку в открытом доступе.

---

## 📦 Ручная установка

Если one-click installer не нужен:

```bash
git clone https://github.com/vanitoo/telegram-mtproxy.git
cd telegram-mtproxy
cp .env.example .env
docker compose up -d --build
```

При необходимости укажите публичный IPv4 в `.env`:

```dotenv
EXTERNAL_IP=203.0.113.10
```

При пустом `EXTERNAL_IP` контейнер попробует определить адрес автоматически.

> При ручной установке cron автоматически не создаётся. Для ежедневного обновления конфигурации используйте one-click installer или добавьте `docker compose restart mtproxy` в cron самостоятельно.

---

## 🩺 Диагностика

Проверить итоговую Compose-конфигурацию:

```bash
docker compose config --quiet
```

Проверить, слушается ли порт:

```bash
ss -ltnp
```

Последние логи:

```bash
docker compose logs --tail=200 mtproxy
```

Если прокси не доступен снаружи:

- проверьте firewall сервера;
- проверьте security group у хостинг-провайдера;
- убедитесь, что выбранный TCP-порт свободен;
- при NAT явно задайте `EXTERNAL_IP`;
- проверьте вывод `docker compose logs mtproxy`.

---

## 📁 Структура проекта

| Путь | Назначение |
| --- | --- |
| `Dockerfile` | двухэтапная сборка официального MTProxy |
| `docker-compose.yml` | сервис, порты, переменные, volume и ротация логов |
| `.env.example` | пример пользовательской конфигурации |
| `install.sh` | one-click установка и настройка ежедневного cron |
| `entrypoint.sh` | обновление Telegram-конфигурации, NAT, Fake TLS и запуск |
| `docker_update.sh` | Git update + rebuild + вывод ссылки |
| `data/` | постоянный secret и загружаемая конфигурация Telegram |

---

## 🏗 Docker image

MTProxy собирается из официального репозитория в отдельном build-stage на Ubuntu 24.04.

Финальный контейнер содержит только runtime-зависимости, бинарный `mtproto-proxy` и `entrypoint.sh`. Сам MTProxy запускается с параметром `-u mtproxy`.

Проект не устанавливает MTProxy непосредственно в систему и не создаёт отдельный systemd-сервис для прокси.
