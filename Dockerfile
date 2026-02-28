FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    curl \
    cron \
    default-mysql-client \
    ca-certificates \
    openssh-client \
    gosu \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

RUN useradd -m -s /bin/bash dev

RUN gosu dev git config --global user.name "dev" && \
    gosu dev git config --global user.email "dev@dolt.local" && \
    gosu dev dolt config --global --add user.name "dev" && \
    gosu dev dolt config --global --add user.email "dev@dolt.local"

COPY --chmod=755 bin/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 bin/sync.sh /usr/local/bin/sync.sh

USER dev

EXPOSE 3307

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
