FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    ca-certificates \
    sqlite3 \
    dos2unix \
    expect \
    iputils-ping \
    procps \
    jq \
    openssl \
    && rm -rf /var/lib/apt/lists/*

COPY patch.sh update.sh docker-entrypoint.sh configure-nessus.sh nessus-proxy.sh /usr/local/bin/

RUN dos2unix /usr/local/bin/patch.sh \
    /usr/local/bin/update.sh \
    /usr/local/bin/docker-entrypoint.sh \
    /usr/local/bin/configure-nessus.sh \
    /usr/local/bin/nessus-proxy.sh \
    && chmod +x \
    /usr/local/bin/patch.sh \
    /usr/local/bin/update.sh \
    /usr/local/bin/docker-entrypoint.sh \
    /usr/local/bin/configure-nessus.sh \
    && chmod 644 /usr/local/bin/nessus-proxy.sh

EXPOSE 8834

STOPSIGNAL SIGTERM

CMD ["/usr/local/bin/docker-entrypoint.sh"]
