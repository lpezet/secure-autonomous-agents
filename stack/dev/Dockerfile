FROM mcr.microsoft.com/devcontainers/typescript-node:22

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*
