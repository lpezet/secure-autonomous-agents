FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    gosu \
    jq \
    ca-certificates \
    unzip \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs python3 python3-sklearn python3-pip python3-pil python3-numpy \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN usermod -l agent ubuntu \
    && usermod -d /home/agent -m agent \
    && groupmod -n agent ubuntu

USER agent
ENV HOME=/home/agent
RUN curl -fsSL https://bun.sh/install | bash

ENV BUN_INSTALL="/home/agent/.bun"
ENV PATH="/home/agent/.local/bin:/home/agent/.bun/bin:${PATH}"

# Claude Code is installed last so busting this layer doesn't redo apt/node/bun.
# Accepts "latest" (default), "stable", or an exact version like "2.1.5".
# Change the value to force a re-download — Docker caches this RUN otherwise:
#   docker compose build --build-arg CLAUDE_VERSION=stable dev
#   docker compose up -d --force-recreate dev
# To re-build dev from scratch:
#   docker compose build --no-cache dev
ARG CLAUDE_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}"

WORKDIR /home/agent

USER root
COPY setup.sh /setup.sh
COPY plugins.sh /plugins.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /setup.sh /plugins.sh /entrypoint.sh

CMD ["/entrypoint.sh"]
