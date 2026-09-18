FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git build-essential libssl-dev zlib1g-dev ca-certificates && \
    git clone --depth=1 https://github.com/TelegramMessenger/MTProxy.git /src && \
    cd /src && \
    make -j"$(nproc)"

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl openssl && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --no-create-home --shell /usr/sbin/nologin mtproxy

WORKDIR /app

COPY --from=builder /src/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    mkdir -p /data /control && \
    chown -R mtproxy:mtproxy /data && \
    chown 10001:10001 /control

ENTRYPOINT ["/entrypoint.sh"]
